package com.noop.testcentre

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Twin of the Swift TestBundleAssemblerTests: an injected serial is scrubbed in a non-sink file. */
class TestBundleAssemblerTest {

    @Test fun reScrubsEveryFileIncludingRawCapture() {
        val rawWithSerial = "{\"console\":\"connected to WHOOP 4C1594026 ok\"}"
        val entries = listOf(
            "report.txt" to "clean line".toByteArray(),
            "raw-capture.jsonl" to rawWithSerial.toByteArray())
        val scrubbed = TestBundleAssembler.redactEntries(entries)
        val raw = scrubbed.first { it.first == "raw-capture.jsonl" }.second
        val text = String(raw)
        assertFalse(text.contains("4C1594026"))
        assertTrue(text.contains("WHOOP <serial>"))
    }

    @Test fun stampsRedactionV2() {
        assertEquals("v2", TestBundleAssembler.REDACTION_VERSION)
    }

    @Test fun capTruncatesRawCaptureTailAndFlags() {
        val small = "report.txt" to "small".toByteArray()
        val oversized = "x".repeat(40 * 1024 * 1024).toByteArray()  // 40 MB raw-capture
        val entries = listOf(small, "raw-capture.jsonl" to oversized)

        val (capped, truncated) = TestBundleAssembler.capEntries(entries, 20 * 1024 * 1024)
        assertTrue(truncated)
        val total = capped.sumOf { it.second.size }
        assertTrue(total <= 20 * 1024 * 1024)
        assertArrayEquals("small".toByteArray(), capped.first { it.first == "report.txt" }.second)
        val raw = capped.first { it.first == "raw-capture.jsonl" }.second
        assertTrue(raw.size < oversized.size)
        // The tail (most recent) survives: the last byte matches.
        assertEquals(oversized.last(), raw.last())
    }

    @Test fun capLeavesUndersizedBundleUntouched() {
        val entries = listOf("report.txt" to "tiny".toByteArray())
        val (capped, truncated) = TestBundleAssembler.capEntries(entries, 20 * 1024 * 1024)
        assertFalse(truncated)
        assertEquals(1, capped.size)
        assertArrayEquals("tiny".toByteArray(), capped.first().second)
    }
}
