package com.noop.protocol

/**
 * Decoded stream rows — the durable, compact local record produced from parsed frames.
 *
 * Ported from the Swift reference (Streams.swift). `ts` is wall-clock unix seconds throughout.
 * These are pure data carriers with no Android/Room dependency; the data layer maps them onto
 * Room entities (HrSample, RrInterval, EventRow, BatterySample) as needed.
 */

/** A heart-rate sample at wall-clock unix seconds [ts]. */
data class HrSample(val ts: Int, val bpm: Int)

/** A single beat-to-beat R-R interval (ms) at wall-clock unix seconds [ts]. */
data class RrInterval(val ts: Int, val rrMs: Int)

/**
 * A raw-ADC SpO2 sample at wall-clock unix seconds [ts]. Mirrors the Room `Spo2Sample` (red/ir)
 * and the Swift `SpO2Sample(red:ir:unit:)` shape so [StreamPersistence.toBatch] is a 1:1 widen.
 * Historically only the type-47 historical-offload path produced these; the live carrier now also
 * carries them so a single-value optical source (the Oura ring exposes ONE combined SpO2 reading,
 * not separate red/ir channels) can flow live. Such a source puts its raw value in [red] and
 * leaves [ir] at 0 (an unread channel, never a fabricated second reading).
 *
 * [unit] preserves the decoder's own scale tag (e.g. "raw_adc"/"raw"/"dc_raw") so a downstream
 * reader never assumes a percentage. This mirrors the unit fidelity the Swift `SpO2Sample` carries,
 * so the unit is not silently dropped on the Kotlin side at the carrier level. (The Room `Spo2Sample`
 * entity has no unit column yet; the carrier-level tag documents the convention until a migration
 * adds one.)
 */
data class Spo2Sample(val ts: Int, val red: Int, val ir: Int, val unit: String = "raw_adc")

/**
 * A skin-temperature sample at wall-clock unix seconds [ts]. Mirrors the Room `SkinTempSample` and
 * the Swift `SkinTempSample(raw:unit:)` shape.
 *
 * UNIT CONVENTION (codebase-wide): [raw] is an integer in CENTI-degrees C (°C = raw / 100). The WHOOP
 * @73 historical path stores raw at this scale and the analytics reader (AnalyticsEngine /
 * wornNightlySkinTempC, both platforms) divides raw by 100 to recover °C. The live Oura path stores
 * the SAME celsius * 100, so a given decoded celsius yields an IDENTICAL raw integer on Android and
 * macOS. [unit] carries the scale tag ("centi_c") explicitly so it is never silently assumed; it
 * mirrors the Swift `SkinTempSample.unit`. (The Room entity has no unit column yet; this carrier-level
 * tag plus this comment document the convention until a migration adds one.)
 */
data class SkinTempSample(val ts: Int, val raw: Int, val unit: String = "raw_adc")

/**
 * A device event. [ts] is real RTC unix seconds (already wall-clock, never offset). [kind] is the
 * event label (e.g. "BATTERY_LEVEL(3)", "WRIST_OFF(10)"); [payload] carries any extra decoded
 * fields with `event`/`event_timestamp` removed.
 */
data class WhoopEvent(val ts: Int, val kind: String, val payload: Map<String, Any?>)

/**
 * A battery reading. [ts] is event RTC for BATTERY_LEVEL events, else the wall-clock reference.
 * [charging] is a real Boolean only when the frame reported it (BATTERY_LEVEL events); `null`
 * otherwise (command responses).
 */
data class BatterySample(
    val ts: Int,
    val soc: Double?,
    val mv: Int?,
    val charging: Boolean? = null,
)

/** The bundle of decoded series extracted from a batch of parsed frames. */
data class Streams(
    val hr: MutableList<HrSample> = mutableListOf(),
    val rr: MutableList<RrInterval> = mutableListOf(),
    val events: MutableList<WhoopEvent> = mutableListOf(),
    val battery: MutableList<BatterySample> = mutableListOf(),
    // spo2/skinTemp default empty so every existing WHOOP-path constructor/extractStreams call site is
    // unchanged; only a source that decodes these biometric signals live (the Oura ring) populates them.
    val spo2: MutableList<Spo2Sample> = mutableListOf(),
    val skinTemp: MutableList<SkinTempSample> = mutableListOf(),
) {
    companion object {
        val EMPTY: Streams get() = Streams()
    }
}

/**
 * Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
 * Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of `_to_wall`.
 */
private fun toWall(deviceTs: Int?, deviceClockRef: Int, wallClockRef: Int): Int? {
    if (deviceTs == null) return null
    return wallClockRef + (deviceTs - deviceClockRef)
}

/**
 * Turn parsed frames into datastore rows. Port of `interpreter.extract_streams`.
 *
 * HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also carries an
 * HR byte but streams alongside type-40 during raw collection, so routing both would double-count
 * HR for the same instants. CRC-failed and non-ok frames are skipped.
 */
fun extractStreams(parsed: List<ParsedFrame>, deviceClockRef: Int, wallClockRef: Int): Streams {
    val out = Streams()
    for (r in parsed) {
        if (!r.ok || r.crcOk == false) continue
        val p = r.parsed
        when (r.typeName) {
            "REALTIME_DATA" -> {
                val ts = toWall(p.intOrNull("timestamp"), deviceClockRef, wallClockRef)
                if (ts != null) {
                    p.intOrNull("heart_rate")?.let { bpm -> out.hr.add(HrSample(ts, bpm)) }
                    // Drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
                    p.intArrayOrNull("rr_intervals")?.let { rrs ->
                        for (rr in rrs) out.rr.add(RrInterval(ts, rr))
                    }
                }
            }

            "EVENT" -> {
                // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
                val ts = p.intOrNull("event_timestamp") ?: continue
                val kind = p.stringOrNull("event") ?: ""
                // BATTERY_LEVEL events (~every 8 min) carry SoC/mV/charging → the DENSE series.
                if (kind.startsWith("BATTERY_LEVEL")) appendBattery(out, ts, p)
                val payload = p.toMutableMap()
                payload.remove("event")
                payload.remove("event_timestamp")
                out.events.add(WhoopEvent(ts, kind, payload))
            }

            "COMMAND_RESPONSE" -> {
                // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
                appendBattery(out, wallClockRef, p)
            }

            else -> Unit
        }
    }
    return out
}

/**
 * Append a [BatterySample] from a parsed frame's `battery_pct`/`battery_mV`/`battery_charging`
 * fields (no-op when neither soc nor mv is present). `charging` is a real Boolean only when the
 * frame reported it (BATTERY_LEVEL events); command responses leave it null.
 */
internal fun appendBattery(out: Streams, ts: Int, p: Map<String, Any?>) {
    val soc = p.doubleOrNull("battery_pct")
    val mv = p.intOrNull("battery_mV")
    if (soc == null && mv == null) return
    val charging = p.intOrNull("battery_charging")?.let { it != 0 }
    out.battery.add(BatterySample(ts = ts, soc = soc, mv = mv, charging = charging))
}

// MARK: - Heterogeneous parsed-map accessors (mirror Swift's ParsedValue.intValue/etc.)

internal fun Map<String, Any?>.intOrNull(key: String): Int? = when (val v = this[key]) {
    is Int -> v
    is Long -> v.toInt()
    else -> null
}

internal fun Map<String, Any?>.doubleOrNull(key: String): Double? = when (val v = this[key]) {
    is Double -> v
    is Int -> v.toDouble()
    is Long -> v.toDouble()
    else -> null
}

internal fun Map<String, Any?>.stringOrNull(key: String): String? = this[key] as? String

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.intArrayOrNull(key: String): List<Int>? = this[key] as? List<Int>
