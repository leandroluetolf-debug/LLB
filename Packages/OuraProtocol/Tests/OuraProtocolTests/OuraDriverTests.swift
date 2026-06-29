import XCTest
@testable import OuraProtocol

/// OuraDriver flow tests: the transport-agnostic state machine drives scan -> auth -> enable -> stream
/// purely from transitions (no BLE), and ingest(record:) decodes records (with Tier-B gating).
final class OuraDriverTests: XCTestCase {
    private let key: [UInt8] = Array(0..<16)   // deterministic 16-byte app key
    private let rt: UInt32 = 0x0001_0002

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: - Full happy-path step sequence (auth -> enable triplet -> streaming)

    func testFullEnableSequence() throws {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        XCTAssertEqual(d.phase, .idle)

        // ready -> enable notifications + request nonce.
        let onReady = d.nextStep(after: .ready)
        XCTAssertEqual(d.phase, .authenticating)
        XCTAssertEqual(onReady.map { $0.label }, ["notify_all", "get_nonce"])
        XCTAssertEqual(onReady[1].bytes, [0x2F, 0x01, 0x2B])

        // nonce -> submit proof.
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let onNonce = d.nextStep(after: .nonceReceived(nonce))
        XCTAssertEqual(onNonce.count, 1)
        XCTAssertEqual(Array(onNonce[0].bytes[0..<3]), [0x2F, 0x11, 0x2D])
        // The proof body matches the known vector.
        XCTAssertEqual(Array(onNonce[0].bytes[3...]), bytes("c49fb9e83c46087a555183a9dc511ee9"))

        // auth success -> first live-HR enable step (read DHR status).
        let onAuth = d.nextStep(after: .authCompleted(.success))
        XCTAssertEqual(d.phase, .enablingLiveHR)
        XCTAssertEqual(onAuth.map { $0.label }, ["dhr_read"])
        XCTAssertEqual(onAuth[0].bytes, [0x2F, 0x02, 0x20, 0x02])

        // ack 1 -> enable ; ack 2 -> subscribe ; ack 3 -> streaming (no more commands).
        let step2 = d.nextStep(after: .enableAckReceived)
        XCTAssertEqual(step2.map { $0.label }, ["dhr_enable"])
        XCTAssertEqual(step2[0].bytes, [0x2F, 0x03, 0x22, 0x02, 0x03])

        let step3 = d.nextStep(after: .enableAckReceived)
        XCTAssertEqual(step3.map { $0.label }, ["dhr_subscribe"])
        XCTAssertEqual(step3[0].bytes, [0x2F, 0x03, 0x26, 0x02, 0x02])

        let done = d.nextStep(after: .enableAckReceived)
        XCTAssertTrue(done.isEmpty)
        XCTAssertEqual(d.phase, .streaming)
    }

    // MARK: - Honest pairing path when no key

    func testNoKeyDrivesNeedsKeyInstall() {
        let d = OuraDriver(ringGen: .gen3, authKey: nil)
        let cmds = d.nextStep(after: .ready)
        XCTAssertTrue(cmds.isEmpty, "without an app key we cannot authenticate; emit no commands")
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    func testFactoryResetStatusDrivesNeedsKeyInstall() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        _ = d.nextStep(after: .ready)
        let cmds = d.nextStep(after: .authCompleted(.inFactoryReset))
        XCTAssertTrue(cmds.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    func testAuthErrorIsSurfacedNotRetriedBlindly() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        _ = d.nextStep(after: .ready)
        _ = d.nextStep(after: .authCompleted(.authError))
        XCTAssertEqual(d.phase, .authFailed(.authError))
    }

    // MARK: - Post-factory-reset key install sequencing (s3.2), gated on allowKeyInstall

    /// With allowKeyInstall == true the adopt flow sequences needsKeyInstall -> installingKey ->
    /// (on the 0x25 ack) re-auth, and the post-install re-auth uses the freshly-provisioned key.
    func testKeyInstallSequencesReauthWhenAllowed() throws {
        // No injected key -> the honest needs-pairing path; the transport will provision one.
        let d = OuraDriver(ringGen: .gen3, authKey: nil, allowKeyInstall: true)
        let onReady = d.nextStep(after: .ready)
        XCTAssertTrue(onReady.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)

        // The transport generates + persists a fresh 16-byte key and asks the driver for the install
        // command. It must be the DANGEROUS `24 10 <key>` write (s3.2) and advance to installingKey.
        let install = d.beginKeyInstall(key: key)
        XCTAssertNotNil(install)
        XCTAssertEqual(install?.label, "DANGEROUS_install_key")
        XCTAssertEqual(install?.bytes, [0x24, 0x10] + key)
        XCTAssertEqual(d.phase, .installingKey)

        // The ring acks with `25 01 00`; the transport calls back and the driver drives re-auth.
        let onAck = d.keyInstallAcknowledged()
        XCTAssertEqual(onAck.map { $0.label }, ["notify_all", "get_nonce"])
        XCTAssertEqual(onAck[1].bytes, [0x2F, 0x01, 0x2B])
        XCTAssertEqual(d.phase, .authenticating)

        // Re-auth uses the freshly-installed key: the proof matches the known vector for that key.
        let nonce = bytes("0102030405060708090a0b0c0d0e0f")
        let onNonce = d.nextStep(after: .nonceReceived(nonce))
        XCTAssertEqual(onNonce.count, 1)
        XCTAssertEqual(Array(onNonce[0].bytes[0..<3]), [0x2F, 0x11, 0x2D])
        XCTAssertEqual(Array(onNonce[0].bytes[3...]), bytes("c49fb9e83c46087a555183a9dc511ee9"))
    }

    /// With allowKeyInstall == false (the default) the driver MUST NOT sequence an install: it stays at
    /// needsKeyInstall, emits no command, and a stray 0x25 ack cannot advance the flow.
    func testNoKeyInstallSequencedWhenNotAllowed() {
        let d = OuraDriver(ringGen: .gen3, authKey: nil)   // allowKeyInstall defaults to false
        _ = d.nextStep(after: .ready)
        XCTAssertEqual(d.phase, .needsKeyInstall)

        let install = d.beginKeyInstall(key: key)
        XCTAssertNil(install, "no dangerous 0x24 write may be produced without an opt-in adopt flow")
        XCTAssertEqual(d.phase, .needsKeyInstall, "phase must stay needsKeyInstall")

        // A stray ack must be ignored too (no install was sequenced, so there is nothing to acknowledge).
        let onAck = d.keyInstallAcknowledged()
        XCTAssertTrue(onAck.isEmpty)
        XCTAssertEqual(d.phase, .needsKeyInstall)
    }

    /// Even with allowKeyInstall == true, beginKeyInstall only fires from needsKeyInstall; a call from
    /// another phase is a no-op (the gate is BOTH the flag and the phase).
    func testKeyInstallIgnoredOutsideNeedsKeyInstallPhase() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowKeyInstall: true)
        _ = d.nextStep(after: .ready)        // -> authenticating (a real key is present)
        XCTAssertEqual(d.phase, .authenticating)
        XCTAssertNil(d.beginKeyInstall(key: key), "install must not fire outside needsKeyInstall")
        XCTAssertEqual(d.phase, .authenticating)
    }

    // MARK: - History fetch loop

    func testHistoryFetchFlushesThenFetchesThenAcks() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let start = d.nextStep(after: .startHistoryFetch(cursor: 0))
        XCTAssertEqual(d.phase, .fetchingHistory)
        XCTAssertEqual(start.map { $0.label }, ["flush_buffer", "get_events"])
        // get_events cursor 0, max 255, flags FFFFFFFF.
        XCTAssertEqual(start[1].bytes, [0x10, 0x09, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        // More data -> ack-fetch (max 0) at the advanced cursor.
        let ack = d.nextStep(after: .historyCursorAdvanced(cursor: 0x12345678, moreData: true))
        XCTAssertEqual(ack.count, 1)
        XCTAssertEqual(ack[0].bytes, [0x10, 0x09, 0x78, 0x56, 0x34, 0x12, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])

        // No more -> back to streaming.
        let stop = d.nextStep(after: .historyCursorAdvanced(cursor: 0x12345678, moreData: false))
        XCTAssertTrue(stop.isEmpty)
        XCTAssertEqual(d.phase, .streaming)
    }

    // MARK: - ingest(record:) decoding

    func testIngestDecodesTierARecord() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // 0x7B SpO2 stable record -> one spo2 event (970, BE).
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))!
        let events = d.ingest(record: rec)
        XCTAssertEqual(events, [.spo2(OuraSpO2(ringTimestamp: rt, value: 970))])
    }

    func testIngestUnknownTagYieldsNothing() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // 0x99 is not in the dictionary -> [] (never a guessed value).
        let rec = OuraRecord(type: 0x99, ringTimestamp: rt, payload: [0x01, 0x02])
        XCTAssertEqual(d.ingest(record: rec), [])
    }

    // MARK: - Tier-B gating

    func testTierBDroppedByDefault() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)   // allowTierB defaults to false
        // 0x49 sleep_summary_1 is Tier B (UNVERIFIED).
        let rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!
        XCTAssertEqual(d.ingest(record: rec), [], "Tier-B must not feed values when not explicitly allowed")
    }

    func testTierBEmittedOnlyWhenAllowed() {
        let d = OuraDriver(ringGen: .gen3, authKey: key, allowTierB: true)
        let rec = OuraFraming.parseRecord(bytes("49080200010001020304"))!
        let events = d.ingest(record: rec)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isTierB)
        if case .tierB(let summary) = events[0] {
            XCTAssertEqual(summary.tag, 0x49)
            XCTAssertEqual(summary.kind, "sleep_summary")
            XCTAssertEqual(summary.rawPayload, bytes("01020304"))
        } else {
            XCTFail("expected a tierB event")
        }
    }

    // MARK: - Live-HR push routing + decode

    func testHandleSecureFrameRoutesNonceStatusAndPush() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let nonceFrame = OuraSecureFrame(subop: 0x2C, subBody: bytes("0102030405060708090a0b0c0d0e0f"))
        XCTAssertEqual(d.handleSecureFrame(nonceFrame), .nonce(bytes("0102030405060708090a0b0c0d0e0f")))

        let statusFrame = OuraSecureFrame(subop: 0x2E, subBody: [0x00])
        XCTAssertEqual(d.handleSecureFrame(statusFrame), .authStatus(.success))

        let ackFrame = OuraSecureFrame(subop: 0x23, subBody: [0x02, 0x00])
        XCTAssertEqual(d.handleSecureFrame(ackFrame), .enableAck)

        // The push subBody is the 14 bytes AFTER `2f 0f 28` from the s5.6 wire frame (IBI at [5..6]).
        let pushBody = bytes("020002000001040000000000007f")
        XCTAssertEqual(pushBody.count, 14)
        XCTAssertEqual(d.handleSecureFrame(OuraSecureFrame(subop: 0x28, subBody: pushBody)), .liveHRPush(pushBody))
    }

    func testLiveHRPushIngestStampsLastRingTime() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        // Ingest a TLV record first so the driver learns a ring time to stamp the push with.
        let rec = OuraFraming.parseRecord(bytes("420d0200010000d2dd639001000002"))!
        _ = d.ingest(record: rec)
        // The push body is the 14-byte s5.6 subBody (after `2f 0f 28`); IBI at [5..6] = 01 04 -> 1025 ms.
        let push = bytes("020002000001040000000000007f")
        let events = d.ingestLiveHRPush(body: push)
        XCTAssertEqual(events, [
            .hr(OuraHR(ringTimestamp: rt, bpm: 59, ibiMs: 1025)),
            .ibi(OuraIBI(ringTimestamp: rt, ibiMs: 1025)),
        ])
    }

    // MARK: - Notification-level ingest via reassembler

    func testIngestNotificationReassemblesAndDecodes() {
        let d = OuraDriver(ringGen: .gen3, authKey: key)
        let reassembler = OuraReassembler()
        // Two records packed together: 0x7B SpO2 then 0x46 temp.
        let value = bytes("7b060200010003ca" + "460802000100420e470e")
        let events = d.ingest(notification: value, reassembler: reassembler)
        XCTAssertEqual(events, [
            .spo2(OuraSpO2(ringTimestamp: rt, value: 970)),
            .temp(OuraTemp(ringTimestamp: rt, celsius: 36.50)),
            .temp(OuraTemp(ringTimestamp: rt, celsius: 36.55)),
        ])
    }

    // MARK: - Generation-driven command set / MTU

    func testRingGenMtuAndCaps() {
        XCTAssertEqual(OuraRingGen.gen3.mtu, 203)
        XCTAssertEqual(OuraRingGen.gen5.mtu, 247)
        XCTAssertTrue(OuraRingGen.gen5.hasExtraNotifyChars)
        XCTAssertFalse(OuraRingGen.gen3.hasExtraNotifyChars)
        XCTAssertEqual(OuraRingGen.from(model: "Oura Ring 5"), .gen5)
        XCTAssertEqual(OuraRingGen.from(model: "Oura Ring 3"), .gen3)
        XCTAssertTrue(OuraRingGen.gen3.capabilities.contains(.hrv))
    }

    func testSyncTimeCommandCounter() {
        // counter = floor(unix / 256). For unix = 256 -> counter 1 -> bytes 01 00 00, trailer 0xF6.
        let cmd = OuraCommands.syncTime(unixSeconds: 256)
        XCTAssertEqual(cmd.bytes, [0x12, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF6])
    }

    // MARK: - Dangerous commands are isolated and labelled

    func testDangerousCommandsAreClearlyNamed() {
        XCTAssertEqual(OuraDangerousCommands.softReset().bytes, [0x0E, 0x01, 0xFF])
        XCTAssertTrue(OuraDangerousCommands.softReset().label.hasPrefix("DANGEROUS_"))
        XCTAssertTrue(OuraDangerousCommands.factoryReset().label.hasPrefix("DANGEROUS_"))
        // The normal command builders never produce a reboot/reset opcode.
        XCTAssertNotEqual(OuraCommands.getBattery().bytes.first, 0x0E)
        XCTAssertNotEqual(OuraCommands.getBattery().bytes.first, 0x1A)
    }
}
