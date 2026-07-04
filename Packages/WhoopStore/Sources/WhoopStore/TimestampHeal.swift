import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Outcome of a one-time implausible-timestamp heal (#547). `rawRowsDeleted` = garbage raw stream
    /// rows purged (HR/RR/SpO2/skinTemp/resp/gravity/step/ppgHr/event/battery). `computedRowsDeleted` =
    /// future/implausible computed daily-metric + sleep-session rows purged. `didChange` is true when
    /// anything was deleted, so the caller can trigger a single rescore instead of always re-running it.
    public struct TimestampHealResult: Equatable, Sendable {
        public let rawRowsDeleted: Int
        public let computedRowsDeleted: Int
        public var didChange: Bool { rawRowsDeleted > 0 || computedRowsDeleted > 0 }
        public init(rawRowsDeleted: Int, computedRowsDeleted: Int) {
            self.rawRowsDeleted = rawRowsDeleted
            self.computedRowsDeleted = computedRowsDeleted
        }
    }

    /// ONE-TIME repair of a database polluted by a bad-clock strap (#547, pikapik). Before the ingest
    /// gate landed, LLB trusted each type-47 record's own unix timestamp verbatim, so a WHOOP with a
    /// broken clock/flash (repeated trim=0xFFFFFFFF) wrote rows dated to scattered garbage — far-past
    /// (2024/2029), a bogus 2027=1827642881, and FUTURE dates. The day-windows overlap, so one ~12h
    /// polluted block was re-attributed to every day (the repeated totalSleepMin=721 across 06-14..06-21)
    /// and a future-dated record made the Today "last night" carry-over read "12 Jul".
    ///
    /// This purges that garbage so a normal rescore recomputes the real days cleanly:
    ///   (a) raw stream rows whose `ts` is implausible (< MIN_PLAUSIBLE_UNIX or > now + FUTURE_MARGIN) —
    ///       across every time-keyed raw table the gate now protects;
    ///   (b) computed `dailyMetric` rows whose `day` is in the future (> today, local) or implausibly old,
    ///       and `sleepSession` rows whose `startTs` is future/implausible.
    /// The caller then triggers a normal `analyzeRecent` so the real days recompute (the 721 block is
    /// gone once its garbage raw rows are purged). Idempotent: a re-run on a clean DB deletes nothing.
    ///
    /// `now` and `todayLocalDayKey` are injected (default to the live wall clock / today's yyyy-MM-dd in
    /// the local zone) so the heal is deterministically unit-testable. Bounds come straight from
    /// WhoopProtocol so Swift and the Android Room cleanup reject the identical set.
    @discardableResult
    public func healImplausibleTimestamps(
        now: Int = Int(Date().timeIntervalSince1970),
        todayLocalDayKey: String = WhoopStore.localDayKey(Date())
    ) async throws -> TimestampHealResult {
        let lo = MIN_PLAUSIBLE_UNIX
        let hi = now + FUTURE_MARGIN
        return try syncWrite { db in
            // (a) Raw, ts-keyed streams. Every one of these is fed by the historical type-47 / EVENT /
            // REALTIME paths the #547 gate now guards, so the same out-of-bounds predicate cleans them.
            let rawTables = ["hrSample", "rrInterval", "event", "battery",
                             "spo2Sample", "skinTempSample", "respSample",
                             "gravitySample", "stepSample", "ppgHrSample"]
            var rawDeleted = 0
            for table in rawTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE ts < ? OR ts > ?",
                               arguments: [lo, hi])
                rawDeleted += db.changesCount
            }

            // (b) Computed rows. dailyMetric is keyed by a yyyy-MM-dd `day` text — drop any day AFTER
            // today (a future row can only come from a future-dated record) or implausibly far in the
            // past (before the 2023-11 floor's day). String comparison is correct for the zero-padded
            // yyyy-MM-dd format. The far-past floor key is derived from MIN_PLAUSIBLE_UNIX in UTC so it
            // is a fixed sentinel independent of the device's zone.
            let floorDayKey = WhoopStore.utcDayKey(MIN_PLAUSIBLE_UNIX)
            var computedDeleted = 0
            try db.execute(sql: "DELETE FROM dailyMetric WHERE day > ? OR day < ?",
                           arguments: [todayLocalDayKey, floorDayKey])
            computedDeleted += db.changesCount
            // sleepSession is keyed by an integer `startTs` — drop future/implausible sessions.
            try db.execute(sql: "DELETE FROM sleepSession WHERE startTs < ? OR startTs > ?",
                           arguments: [lo, hi])
            computedDeleted += db.changesCount

            return TimestampHealResult(rawRowsDeleted: rawDeleted,
                                       computedRowsDeleted: computedDeleted)
        }
    }

    /// `yyyy-MM-dd` for `date` in the LOCAL calendar — matches how dailyMetric `day` keys are written.
    public static func localDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `yyyy-MM-dd` for a unix second in UTC — a zone-independent sentinel for the far-past floor day.
    public static func utcDayKey(_ unix: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}
