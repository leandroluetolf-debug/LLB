package com.noop.oura

// OuraDriver: the transport-agnostic protocol state machine. Kotlin twin of OuraDriver.swift. It holds
// NO BLE handle: the app's live source owns the BluetoothGatt / CBCentralManager and feeds the driver
// only bytes + transition events. This is what makes the protocol headless-testable (no
// android.bluetooth, no CoreBluetooth anywhere in this package).
//
// Two entry points:
//   - nextStep(after:) -> List<OuraCommand>   : given the last transition, return the commands to write.
//   - ingest(record:) -> List<OuraEvent>      : given a parsed TLV record, return decoded events.
//   - ingestLiveHRPush(body:) -> List<OuraEvent> : given a 0x2F sub-op 0x28 push body, return live HR.
//
// The flow mirrors OURA_PROTOCOL.md s3 (auth) + s5 (live HR / fetch): scan -> connect -> notify ->
// auth (nonce, proof) -> enable live HR (gen-appropriate triplet) -> stream. RingGen swaps the
// command set, not the code path.
//
// Tier discipline: Tier-B decoders are present but gated behind `allowTierB` (default false). When
// false, a Tier-B tag decodes to nothing (the event is dropped), so Tier-B values can never feed
// scoring silently. Per the brief's TIER DISCIPLINE and OURA_PROTOCOL.md s7.3.

/**
 * A transport-level transition the app reports to the driver to advance the flow. The driver answers
 * with the next batch of commands. This keeps all BLE specifics (peripheral, GATT callbacks) in the
 * app and all protocol specifics here. Kotlin twin of Swift's OuraTransition enum.
 */
sealed class OuraTransition {
    /** Service + characteristics discovered and notifications enabled on ...0003. Begin auth. */
    object Ready : OuraTransition()

    /** A 15-byte nonce arrived (from the GetAuthNonce response). Compute + submit the proof. */
    data class NonceReceived(val nonce: IntArray) : OuraTransition() {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is NonceReceived) return false
            return nonce.contentEquals(other.nonce)
        }
        override fun hashCode(): Int = nonce.contentHashCode()
    }

    /** The auth handshake completed with this status. On success, begin enabling live HR. */
    data class AuthCompleted(val status: OuraAuthStatus) : OuraTransition()

    /** A live-HR enable/subscribe ACK arrived; advance the triplet (or, when done, mark streaming). */
    object EnableAckReceived : OuraTransition()

    /** The app wants to fetch buffered history from this cursor (optional path). */
    data class StartHistoryFetch(val cursor: Long) : OuraTransition()

    /** The last GetEvents response advanced the cursor to this value; continue or stop. */
    data class HistoryCursorAdvanced(val cursor: Long, val moreData: Boolean) : OuraTransition()
}

/**
 * The driver's coarse phase, exposed for the app and tests to assert on. Kotlin twin of Swift's
 * OuraDriverPhase enum.
 */
sealed class OuraDriverPhase {
    object Idle : OuraDriverPhase()
    object Authenticating : OuraDriverPhase()
    object EnablingLiveHR : OuraDriverPhase()
    object Streaming : OuraDriverPhase()
    object FetchingHistory : OuraDriverPhase()

    /** Ring is in factory reset; honest pairing path (s3.5 status 0x02). */
    object NeedsKeyInstall : OuraDriverPhase()

    /** Post-factory-reset key install in flight (s3.2); awaiting the 0x25 ack. */
    object InstallingKey : OuraDriverPhase()

    data class AuthFailed(val status: OuraAuthStatus) : OuraDriverPhase()
    object Stopped : OuraDriverPhase()
}

class OuraDriver(
    val ringGen: OuraRingGen,
    /**
     * The 16-byte application auth key (injected, never hardcoded). null drives the honest
     * needs-pairing path (the app surfaces "needsPairing" instead of faking data).
     */
    private val authKey: IntArray?,
    /** When false (default), Tier-B (UNVERIFIED) tags decode to nothing so they can never feed scoring. */
    val allowTierB: Boolean = false,
    /**
     * When false (default), the driver MUST NOT sequence a post-factory-reset key install: it stays at
     * NeedsKeyInstall and writes nothing dangerous. Only an explicit opt-in adopt flow sets this true.
     * Per OURA_PROTOCOL.md s3.2 (the 0x24 SetAuthKey is a DANGEROUS, one-time provisioning write).
     */
    val allowKeyInstall: Boolean = false,
) {
    var phase: OuraDriverPhase = OuraDriverPhase.Idle
        private set

    /** Tracks how many of the live-HR enable triplet ACKs have been seen. */
    private var liveHREnableStep = 0

    /**
     * The most recent ring time seen on any record, used to stamp live-HR pushes (which are not TLV
     * records and carry no timestamp of their own).
     */
    private var lastRingTimestamp: Long = 0

    /**
     * The freshly-provisioned key the transport generated during an adopt flow (s3.2). Once set by
     * beginKeyInstall it becomes the effective key for the post-install re-auth. null otherwise.
     */
    private var installedKey: IntArray? = null

    /**
     * The key the auth handshake should use: the freshly-installed key takes precedence over the
     * injected one (so re-auth after a key install uses the new key). Per OURA_PROTOCOL.md s3.2.
     */
    private val effectiveKey: IntArray?
        get() = installedKey ?: authKey

    // MARK: - Command flow

    /**
     * Given the last transport transition, return the commands the app should write next. Pure: it
     * only mutates the driver's own phase, never touches BLE. Per OURA_PROTOCOL.md s3 / s5.
     */
    fun nextStep(after: OuraTransition): List<OuraCommand> = when (after) {
        is OuraTransition.Ready -> {
            // No app key -> we cannot authenticate; surface the honest pairing path (no faked data).
            if (effectiveKey == null) {
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            } else {
                phase = OuraDriverPhase.Authenticating
                // Enable notifications, then request the auth nonce. SyncTime can follow auth.
                listOf(
                    OuraCommands.enableAllNotifications(),
                    OuraCommand("get_nonce", OuraAuth.getAuthNonceCommand()),
                )
            }
        }

        is OuraTransition.NonceReceived -> {
            val key = effectiveKey
            if (key == null) {
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            } else {
                // Compute the proof and submit it. On any crypto error, fail honestly (no proof sent).
                val cmd = try {
                    OuraAuth.authenticateCommand(after.nonce, key)
                } catch (e: Exception) {
                    null
                }
                if (cmd == null) {
                    phase = OuraDriverPhase.AuthFailed(OuraAuthStatus.AUTH_ERROR)
                    emptyList()
                } else {
                    listOf(OuraCommand("submit_proof", cmd))
                }
            }
        }

        is OuraTransition.AuthCompleted -> when (after.status) {
            OuraAuthStatus.SUCCESS -> {
                phase = OuraDriverPhase.EnablingLiveHR
                liveHREnableStep = 0
                // Begin the live-HR enable triplet (gen-appropriate; gen3 verified, gen4/5 same path).
                listOf(OuraCommands.liveHREnableSequence()[0])
            }
            OuraAuthStatus.IN_FACTORY_RESET -> {
                // Ring needs a key install first; this is an explicit, named provisioning step the app
                // drives, not the normal flow. Surface honestly.
                phase = OuraDriverPhase.NeedsKeyInstall
                emptyList()
            }
            OuraAuthStatus.AUTH_ERROR, OuraAuthStatus.NOT_ORIGINAL_DEVICE -> {
                phase = OuraDriverPhase.AuthFailed(after.status)
                emptyList()
            }
        }

        is OuraTransition.EnableAckReceived -> {
            if (phase != OuraDriverPhase.EnablingLiveHR) {
                emptyList()
            } else {
                liveHREnableStep += 1
                val seq = OuraCommands.liveHREnableSequence()
                if (liveHREnableStep < seq.size) {
                    listOf(seq[liveHREnableStep])
                } else {
                    // All three ACKed: HR/IBI now streams as 0x2F sub-op 0x28 pushes.
                    phase = OuraDriverPhase.Streaming
                    emptyList()
                }
            }
        }

        is OuraTransition.StartHistoryFetch -> {
            phase = OuraDriverPhase.FetchingHistory
            // Flush flash buffer first, then fetch up to 255 events from the cursor (s5.3).
            listOf(
                OuraCommands.flushBuffer(),
                OuraCommands.getEvents(cursor = after.cursor, maxEvents = 255),
            )
        }

        is OuraTransition.HistoryCursorAdvanced -> {
            if (!after.moreData) {
                phase = OuraDriverPhase.Streaming
                emptyList()
            } else {
                // Ack-fetch (max=0) at the new cursor advances without re-pulling data (s5.3 step 4).
                listOf(OuraCommands.getEvents(cursor = after.cursor, maxEvents = 0))
            }
        }
    }

    /**
     * Re-engage live HR (daytime-HR auto-reverts after ~20 s; the app calls this every ~15 s while a
     * live session is open). Per OURA_PROTOCOL.md s5.7. Returns the enable+subscribe commands.
     */
    fun reengageLiveHRCommands(): List<OuraCommand> =
        listOf(OuraCommands.liveHREnable(), OuraCommands.liveHRSubscribe())

    // MARK: - Post-factory-reset key install (adopt flow, s3.2)

    /**
     * Begin the one-time post-factory-reset key install (OURA_PROTOCOL.md s3.2). The transport in the
     * adopt flow generates a fresh 16-byte key, persists it, and calls this to obtain the dangerous
     * `24 10 <key>` write; once the ring replies `25 01 00` the transport calls keyInstallAcknowledged
     * to drive re-auth.
     *
     * SAFETY GATE: this only sequences an install when phase == NeedsKeyInstall AND allowKeyInstall is
     * true. When allowKeyInstall is false it stays at NeedsKeyInstall and returns null, so the
     * dangerous 0x24 write is never emitted outside an explicit opt-in adopt flow. Returns null (and
     * leaves phase unchanged) when not gated on, the key length is wrong, or the command cannot build.
     * Kotlin twin of Swift's beginKeyInstall.
     */
    fun beginKeyInstall(key: IntArray): OuraCommand? {
        if (!allowKeyInstall || phase != OuraDriverPhase.NeedsKeyInstall) return null
        val cmd = try {
            OuraDangerousCommands.installKey(key)
        } catch (e: Exception) {
            null
        } ?: return null
        installedKey = key                 // re-auth after the ack must use the freshly-provisioned key
        phase = OuraDriverPhase.InstallingKey
        return cmd
    }

    /**
     * Handle the ring's 0x25 SetAuthKey ack (`25 01 00`, s3.2) by driving re-auth with the freshly
     * installed key: transition InstallingKey -> Authenticating and return the same enable+nonce
     * commands the ready path uses. Returns [] (phase unchanged) when not in InstallingKey or when no
     * installed key is present, so a stray ack cannot advance the flow. Kotlin twin of Swift's
     * keyInstallAcknowledged.
     */
    fun keyInstallAcknowledged(): List<OuraCommand> {
        if (phase != OuraDriverPhase.InstallingKey || installedKey == null) return emptyList()
        phase = OuraDriverPhase.Authenticating
        return listOf(
            OuraCommands.enableAllNotifications(),
            OuraCommand("get_nonce", OuraAuth.getAuthNonceCommand()),
        )
    }

    /** Stop: reset the flow so a fresh session re-runs auth (the app key is session-scoped, s3.1). */
    fun stop() {
        phase = OuraDriverPhase.Stopped
        liveHREnableStep = 0
        lastRingTimestamp = 0
        installedKey = null
    }

    // MARK: - Record ingest (decode)

    /**
     * Decode one parsed TLV inner record into zero or more events. A malformed/short record (or an
     * unknown tag) yields []. Tier-B tags yield [] unless allowTierB is set. Per OURA_PROTOCOL.md s6.
     */
    fun ingest(record: OuraRecord): List<OuraEvent> {
        lastRingTimestamp = record.ringTimestamp
        val tag = OuraEventTag.fromRaw(record.type)
            // Unknown tag: decode to nothing, never a guessed value (honest-data invariant).
            ?: return emptyList()
        // Tier-B gate: when not explicitly allowed, drop the event so it cannot feed scoring.
        if (tag.tier == TrustTier.TIER_B && !allowTierB) {
            return emptyList()
        }
        return when (tag) {
            // --- Tier A: HR / IBI ---
            OuraEventTag.IBI_AMPLITUDE ->
                (OuraDecoders.decodeIBIAmplitude(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.GREEN_IBI_QUALITY ->
                (OuraDecoders.decodeGreenIBIQuality(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.SPO2_IBI_AMPLITUDE ->
                (OuraDecoders.decodeSpO2IBI(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.IBI ->
                // The bare 0x44 IBI tag shares the bit-packed layout family; route through the same decoder.
                (OuraDecoders.decodeIBIAmplitude(record) ?: emptyList()).map { OuraEvent.Ibi(it) }
            OuraEventTag.GREEN_IBI_AMP ->
                (OuraDecoders.decodeIBIAmplitude(record) ?: emptyList()).map { OuraEvent.Ibi(it) }

            // --- Tier A: HRV ---
            OuraEventTag.HRV_RMSSD ->
                (OuraDecoders.decodeHRV(record) ?: emptyList()).map { OuraEvent.Hrv(it) }

            // --- Tier A: SpO2 ---
            OuraEventTag.SPO2_PER_SAMPLE ->
                (OuraDecoders.decodeSpO2PerSample(record) ?: emptyList()).map { OuraEvent.Spo2(it) }
            OuraEventTag.SPO2_STABLE ->
                OuraDecoders.decodeSpO2Stable(record)?.let { listOf(OuraEvent.Spo2(it)) } ?: emptyList()
            OuraEventTag.SPO2_DC ->
                (OuraDecoders.decodeSpO2DC(record) ?: emptyList()).map { OuraEvent.Spo2(it) }

            // --- Tier A: Temperature ---
            OuraEventTag.TEMP ->
                (OuraDecoders.decodeTemp(record) ?: emptyList()).map { OuraEvent.Temp(it) }
            OuraEventTag.TEMP_PERIOD ->
                OuraDecoders.decodeTempPeriod(record)?.let { listOf(OuraEvent.Temp(it)) } ?: emptyList()
            OuraEventTag.SLEEP_TEMP ->
                (OuraDecoders.decodeSleepTemp(record) ?: emptyList()).map { OuraEvent.Temp(it) }

            // --- Tier A: Motion ---
            OuraEventTag.MOTION_PERIOD ->
                (OuraDecoders.decodeMotionPeriod(record) ?: emptyList()).map { OuraEvent.MotionEvent(it) }
            OuraEventTag.MOTION ->
                // 0x47 motion_events: surfaced as state-free motion is out of v1 scope; decode to nothing
                // rather than guess the partial layout. Per OURA_PROTOCOL.md s6.13.
                emptyList()

            // --- Tier A: Sleep phase (2-bit codes are verified) ---
            OuraEventTag.SLEEP_PHASE, OuraEventTag.SLEEP_PHASE_ALT ->
                (OuraDecoders.decodeSleepPhase(record) ?: emptyList()).map { OuraEvent.SleepPhaseEvent(it) }

            // --- Tier A: Lifecycle / state / time ---
            OuraEventTag.TIME_SYNC ->
                OuraDecoders.decodeTimeSync(record)?.let { listOf(OuraEvent.TimeSyncEvent(it)) } ?: emptyList()
            OuraEventTag.RTC_BEACON ->
                OuraDecoders.decodeRtcBeacon(record)?.let { listOf(OuraEvent.RtcBeaconEvent(it)) } ?: emptyList()
            OuraEventTag.STATE_CHANGE, OuraEventTag.WEAR_EVENT ->
                OuraDecoders.decodeState(record)?.let { listOf(OuraEvent.StateEvent(it)) } ?: emptyList()
            OuraEventTag.DEBUG_TEXT ->
                OuraDecoders.decodeDebugText(record)?.let {
                    listOf(OuraEvent.DebugTextEvent(ringTimestamp = record.ringTimestamp, text = it))
                } ?: emptyList()
            OuraEventTag.RING_START ->
                // 0x41 ring_start_ind: a lifecycle marker (the app uses it to invalidate the UTC anchor on
                // rt regression). It carries no biometric value, so emit nothing here. Per OURA_PROTOCOL.md
                // s5.5 / s6.15. The app observes ring-start via the record stream directly.
                emptyList()

            // --- Tier B (only reached when allowTierB == true; otherwise dropped above) ---
            OuraEventTag.SLEEP_SUMMARY_1, OuraEventTag.SLEEP_SUMMARY_B, OuraEventTag.SLEEP_SUMMARY_C,
            OuraEventTag.SLEEP_SUMMARY_D, OuraEventTag.SLEEP_SUMMARY_E, OuraEventTag.SLEEP_SUMMARY_F ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "sleep_summary",
                        ),
                    ),
                )
            OuraEventTag.ACTIVITY_INFO, OuraEventTag.ACTIVITY_SUMMARY_1, OuraEventTag.ACTIVITY_SUMMARY_2 ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "activity",
                        ),
                    ),
                )
            OuraEventTag.REAL_STEPS_1, OuraEventTag.REAL_STEPS_2 ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "real_steps",
                        ),
                    ),
                )
            OuraEventTag.SPO2_SMOOTHED ->
                listOf(
                    OuraEvent.TierB(
                        OuraTierBSummary(
                            tag = record.type, ringTimestamp = record.ringTimestamp,
                            rawPayload = record.payload, kind = "spo2_smoothed",
                        ),
                    ),
                )
        }
    }

    /**
     * Convenience: ingest a whole notification value by reassembling records and decoding each. The
     * caller passes a fresh notification value; the supplied reassembler buffers partial trailing
     * bytes across calls. Per OURA_PROTOCOL.md s2.4.
     */
    fun ingest(notification: IntArray, reassembler: OuraReassembler): List<OuraEvent> {
        val out = ArrayList<OuraEvent>()
        for (rec in reassembler.feed(notification)) {
            out.addAll(ingest(rec))
        }
        return out
    }

    /**
     * Decode a live-HR push (0x2F sub-op 0x28). The body is the bytes AFTER `2f 0f 28`; the push is
     * not a TLV record, so it is stamped with the last seen ring time. Per OURA_PROTOCOL.md s5.6.
     */
    fun ingestLiveHRPush(body: IntArray): List<OuraEvent> {
        val hr = OuraDecoders.decodeLiveHRPush(body, lastRingTimestamp) ?: return emptyList()
        // The push also carries the IBI; surface both so HRV analytics see the R-R.
        return listOf(
            OuraEvent.Hr(hr),
            OuraEvent.Ibi(OuraIBI(ringTimestamp = lastRingTimestamp, ibiMs = hr.ibiMs)),
        )
    }

    /**
     * Route a parsed secure sub-frame: extract the auth nonce / status, or a live-HR push body, so
     * the app does not need to know the 0x2F sub-op map. Returns the matching transition or push
     * events. Per OURA_PROTOCOL.md s4.2 / s5.6.
     */
    fun handleSecureFrame(frame: OuraSecureFrame): SecureRouting {
        OuraAuth.nonce(frame)?.let { return SecureRouting.Nonce(it) }
        OuraAuth.authStatus(frame)?.let { return SecureRouting.AuthStatus(it) }
        // Sub-op 0x28 carries the live-HR push samples (s5.6). subBody is everything after the subop.
        if (frame.subop == 0x28) {
            return SecureRouting.LiveHRPush(frame.subBody)
        }
        // Enable/subscribe ACKs (0x23 / 0x27) advance the triplet (s5.6).
        if (frame.subop == 0x23 || frame.subop == 0x27) {
            return SecureRouting.EnableAck
        }
        return SecureRouting.Unhandled
    }

    /** What handleSecureFrame resolved a 0x2F sub-frame to. Kotlin twin of Swift's SecureRouting. */
    sealed class SecureRouting {
        data class Nonce(val nonce: IntArray) : SecureRouting() {
            override fun equals(other: Any?): Boolean {
                if (this === other) return true
                if (other !is Nonce) return false
                return nonce.contentEquals(other.nonce)
            }
            override fun hashCode(): Int = nonce.contentHashCode()
        }

        data class AuthStatus(val status: OuraAuthStatus) : SecureRouting()

        data class LiveHRPush(val body: IntArray) : SecureRouting() {
            override fun equals(other: Any?): Boolean {
                if (this === other) return true
                if (other !is LiveHRPush) return false
                return body.contentEquals(other.body)
            }
            override fun hashCode(): Int = body.contentHashCode()
        }

        object EnableAck : SecureRouting()
        object Unhandled : SecureRouting()
    }
}
