package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [relativeAgo], the pure helper behind the Live "History synced N ago" sync-status
 * line (B6 sync-status surfacing). Buckets to just-now / minutes / hours / days; clamps future times.
 */
class RelativeAgoTest {

    private val now = 1_781_000_000L

    private fun ago(sec: Long) = relativeAgo(now - sec, now)

    @Test fun underAMinuteIsJustNow() {
        assertEquals("gerade eben", ago(0))
        assertEquals("gerade eben", ago(59))
    }

    @Test fun minutes() {
        assertEquals("vor 1 Min.", ago(60))
        assertEquals("vor 5 Min.", ago(5 * 60))
        assertEquals("vor 59 Min.", ago(59 * 60))
    }

    @Test fun hours() {
        assertEquals("vor 1 Std.", ago(3600))
        assertEquals("vor 23 Std.", ago(23 * 3600))
    }

    @Test fun days() {
        assertEquals("vor 1 T.", ago(86_400))
        assertEquals("vor 3 T.", ago(3 * 86_400))
    }

    @Test fun futureTimestampClampsToJustNow() {
        // A strap-clock skew could put lastSyncAt slightly in the future; never render negative.
        assertEquals("gerade eben", relativeAgo(now + 500, now))
    }
}
