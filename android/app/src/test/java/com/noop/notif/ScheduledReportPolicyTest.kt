package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pure gate + copy of the #517 scheduled report notifications (the CallAlertPolicy/IllnessAlertPolicy
 * idiom). The Android notifier just wires these to a channel + the persisted dedupe markers, so all the
 * decision logic is verified here without android.*. The HONESTY contract: an absent score is omitted, never
 * shown as 0; both reports fire at most once per logical event, never twice.
 */
class ScheduledReportPolicyTest {

    // MARK: - shouldNotifyMorning (once-per-day gate)

    @Test fun morningFiresWhenEnabledScorePresentAndNotYetToday() {
        assertTrue(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = true, chargeOrRestPresent = true, lastNotifiedDay = "2026-06-20", today = "2026-06-21",
            ),
        )
    }

    @Test fun morningSuppressedWhenDisabled() {
        assertFalse(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = false, chargeOrRestPresent = true, lastNotifiedDay = null, today = "2026-06-21",
            ),
        )
    }

    @Test fun morningSuppressedWhenAlreadyFiredToday() {
        assertFalse(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = true, chargeOrRestPresent = true, lastNotifiedDay = "2026-06-21", today = "2026-06-21",
            ),
        )
    }

    @Test fun morningSuppressedWhenNoScore() {
        assertFalse(
            ScheduledReportPolicy.shouldNotifyMorning(
                enabled = true, chargeOrRestPresent = false, lastNotifiedDay = null, today = "2026-06-21",
            ),
        )
    }

    // MARK: - shouldNotifyWorkout (strictly-newer gate)

    @Test fun workoutFiresForANewerSession() {
        assertTrue(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 2000L, lastWorkoutTs = 1000L))
    }

    @Test fun workoutSuppressedForSameSession() {
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 1000L, lastWorkoutTs = 1000L))
    }

    @Test fun workoutSuppressedForReSyncOfOlderBacklog() {
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 500L, lastWorkoutTs = 1000L))
    }

    @Test fun workoutSuppressedWhenDisabledOrNull() {
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = false, newestWorkoutTs = 2000L, lastWorkoutTs = 1000L))
        assertFalse(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = null, lastWorkoutTs = 1000L))
    }

    @Test fun workoutFiresForTheVeryFirstSession() {
        // lastWorkoutTs == 0 means "none yet"; any real timestamp is newer.
        assertTrue(ScheduledReportPolicy.shouldNotifyWorkout(enabled = true, newestWorkoutTs = 1L, lastWorkoutTs = 0L))
    }

    // MARK: - morningCopy (honest omission)

    @Test fun morningCopyShowsBothScores() {
        val (title, body) = ScheduledReportPolicy.morningCopy(chargePct = 72, restPct = 88)!!
        assertTrue(title.contains("recap"))
        assertTrue(body.contains("Charge 72"))
        assertTrue(body.contains("Rest 88"))
    }

    @Test fun morningCopyOmitsAbsentRestNeverShowsZero() {
        val (_, body) = ScheduledReportPolicy.morningCopy(chargePct = 60, restPct = null)!!
        assertTrue(body.contains("Charge 60"))
        assertFalse(body.contains("Rest"))
    }

    @Test fun morningCopyNullWhenNeitherPresent() {
        assertNull(ScheduledReportPolicy.morningCopy(chargePct = null, restPct = null))
    }

    // MARK: - workoutCopy

    @Test fun workoutCopyIncludesEffortDurationAndHr() {
        val (title, body) = ScheduledReportPolicy.workoutCopy(
            sportLabel = "Laufen", effortDisplay = "14.2", effortMaxLabel = "21",
            durationLabel = "42 Min.", avgHr = 148,
        )
        assertTrue(title.contains("Laufen"))
        assertTrue(title.contains("Training gespeichert"))
        assertTrue(body.contains("Effort 14.2/21"))
        assertTrue(body.contains("42 Min."))
        assertTrue(body.contains("Ø 148 bpm"))
    }

    @Test fun workoutCopyOmitsHrWhenAbsent() {
        val (_, body) = ScheduledReportPolicy.workoutCopy(
            sportLabel = "Radfahren", effortDisplay = "60", effortMaxLabel = "100",
            durationLabel = "1 Std.", avgHr = null,
        )
        assertFalse(body.contains("bpm"))
        assertTrue(body.contains("Effort 60/100"))
    }

    // MARK: - durationLabel

    @Test fun durationLabelFormats() {
        assertEquals("unter einer Minute", ScheduledReportPolicy.durationLabel(0))
        assertEquals("unter einer Minute", ScheduledReportPolicy.durationLabel(-5))
        assertEquals("42 Min.", ScheduledReportPolicy.durationLabel(42))
        assertEquals("1 Std.", ScheduledReportPolicy.durationLabel(60))
        assertEquals("1 Std. 8 Min.", ScheduledReportPolicy.durationLabel(68))
        assertEquals("2 Std.", ScheduledReportPolicy.durationLabel(120))
    }
}
