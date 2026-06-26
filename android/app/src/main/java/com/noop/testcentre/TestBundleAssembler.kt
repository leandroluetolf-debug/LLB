package com.noop.testcentre

import com.noop.ble.redactStrapLogPii

/**
 * Twin of the Swift TestBundleAssembler: gathers the bundle files, re-runs the redaction pass over EVERY
 * file, applies the 20 MB cap, and hands the entries to LogExport.exportBundle.
 *
 * The CRITICAL fix (spec section 5.3): today only the WhoopBleClient.log() sink scrubs, so a serial
 * embedded in raw-capture console text would ship unredacted. We re-run the file-scope redactStrapLogPii
 * over every entry here, the single scrub point, and stamp meta.redaction = "v2".
 */
object TestBundleAssembler {

    const val REDACTION_VERSION = "v2"

    /**
     * Re-run the redaction sink over every entry. Text entries are decoded UTF-8, scrubbed via the same
     * redactStrapLogPii used by the live log sink, and re-encoded. raw-capture is where the embedded
     * serials live; report.txt and meta.json have no PII shapes so they pass through unchanged.
     */
    fun redactEntries(entries: List<Pair<String, ByteArray>>): List<Pair<String, ByteArray>> =
        entries.map { (name, data) ->
            val scrubbed = redactStrapLogPii(String(data))
            name to scrubbed.toByteArray()
        }

    /**
     * Hard cap the bundle at [capBytes] (20 MB default, under GitHub's 25 MB; spec section 5.4). The
     * strap-log tail is already bounded, so only raw-capture can exceed. Keep the MOST-RECENT tail of
     * raw-capture.jsonl and trim from the front. Returns the capped entries plus whether truncation
     * happened, which the caller writes to meta.truncated.
     */
    fun capEntries(
        entries: List<Pair<String, ByteArray>>,
        capBytes: Int = 20 * 1024 * 1024,
    ): Pair<List<Pair<String, ByteArray>>, Boolean> {
        val total = entries.sumOf { it.second.size }
        if (total <= capBytes) return entries to false
        val rawName = "raw-capture.jsonl"
        val nonRaw = entries.filter { it.first != rawName }.sumOf { it.second.size }
        val budget = maxOf(0, capBytes - nonRaw)
        var truncated = false
        val capped = entries.map { (name, data) ->
            if (name == rawName && data.size > budget) {
                truncated = true
                name to data.copyOfRange(data.size - budget, data.size)  // keep the tail
            } else {
                name to data
            }
        }
        return capped to truncated
    }
}
