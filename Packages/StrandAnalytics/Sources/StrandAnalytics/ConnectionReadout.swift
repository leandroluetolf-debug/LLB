import Foundation

// ConnectionReadout.swift - pure values + line formatters for the Connection & Sync test mode.
//
// ConnectionTrace builds the upfront diagnostic lines the Connection emitters write: the CLOCK-DRIFT
// summary (the strap-reported banked-record range vs wall clock, with a future-date flag, promoted from
// the buried raw GET_DATA_RANGE frames to one summary line), the firmware-layout line, and the
// no-cursor / trim sentinel line. ConnectionReadout parses the tagged log tail back into the three
// liveReadout ids the in-app panel binds (connectionUptime, reconnectCount, lastOffloadResult).
//
// Everything here is pure and side-effect-free (no clock read of its own, no I/O), so a fixture pins the
// exact lines and the BLE layer simply gates the call behind TestCentre.active(.connection). No PII -
// counts, durations and ISO dates only. No em-dashes. The Kotlin twin is ConnectionReadout.kt.

public enum ConnectionTrace {

    /// The CLOCK-DRIFT summary line (#767 / #754 cluster): the strap-reported banked-record window
    /// [oldest, newest] against the wall clock, with a FUTURE-DATE flag when the strap's newest record is
    /// dated ahead of wall-now (the tell of a wandering / un-clocked strap). Promoted from the buried raw
    /// GET_DATA_RANGE frames to one upfront `.connection` line so a clock-broken strap is visible at a
    /// glance rather than only via the per-record drop diagnostics.
    ///
    /// All three timestamps are unix seconds in the SAME wall domain (the caller decodes oldest/newest
    /// from the strap's GET_DATA_RANGE reply and passes its own wall-now), so the future-date test is a
    /// plain comparison: `newest > wallNow + tolerance`. `oldest` is optional (a half/short range reply
    /// gives only the upper bound). The span is reported in days for the backlog-depth read.
    ///
    /// - Parameter futureToleranceSeconds: slack before flagging FUTURE (clock skew between the strap RTC
    ///   and the phone is normal up to a minute or two); the default mirrors a couple of minutes.
    public static func clockDriftLine(oldestUnix: Int?,
                                      newestUnix: Int,
                                      wallNowUnix: Int,
                                      futureToleranceSeconds: Int = 120) -> String {
        let iso = isoDate(newestUnix)
        let aheadSeconds = newestUnix - wallNowUnix
        let future = aheadSeconds > futureToleranceSeconds
        var line = "clockDrift newest=\(iso) wall=\(isoDate(wallNowUnix)) "
            + "newestVsWall=\(signed(aheadSeconds))s"
        if let oldestUnix {
            let spanDays = max(0, (newestUnix - oldestUnix)) / 86_400
            line += " oldest=\(isoDate(oldestUnix)) spanDays=\(spanDays)"
        }
        line += future ? " FUTURE-DATED (strap clock ahead of wall)" : " clockOk"
        return line
    }

    /// The firmware-layout line for a HEALTHY sync: which historical record layout the strap emits
    /// (v18/v24/v25/v26). Surfaced once per distinct version so the connection report always reveals the
    /// firmware the strap hands over, not only when LLB cannot decode it.
    public static func firmwareLine(version: Int, decodable: Bool) -> String {
        "firmware layout=v\(version) \(decodable ? "decodable" : "UNMAPPED (no motion/HR decoded)")"
    }

    /// The trim / no-cursor sentinel line: the strap reported trim=0xFFFFFFFF, its "no valid flash cursor"
    /// marker, so it has no banked history to offload (a clock/charge state, not a decode bug).
    public static func noCursorLine() -> String {
        "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)"
    }

    /// Compact ISO-8601 date-time (no fractional seconds), UTC, for the strap-record timestamps. UTC keeps
    /// the line stable across the tester's timezone so a shared report reads identically everywhere.
    static func isoDate(_ unix: Int) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Sign-prefixed integer so the newest-vs-wall delta reads as a signed offset ("+30" / "-3600").
    static func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }
}

/// Pure values for the Connection & Sync live-readout panel. Each parses the `.connection`-tagged log
/// tail the Connection emitters write, so the panel reflects exactly the live link state without the
/// BLE layer having to expose new published properties. No state, no side effects, no em-dashes. The
/// Kotlin twin is the ConnectionReadout object in ConnectionReadout.kt.
public enum ConnectionReadout {

    /// Connection uptime for the readout's `connectionUptime` id. The connect emitter writes
    /// "[connection] connect ... uptimeStart=<unix>" at the instant the link comes up and clears it on
    /// disconnect, so the most recent connect-or-disconnect line tells us whether we are up and since
    /// when. `nowUnix` is injected so the readout is testable without a live clock. Returns a short
    /// human label ("3m 12s" / "not connected").
    public static func uptimeLabel(taggedTail: [String], nowUnix: Int) -> String {
        for line in taggedTail.reversed() {
            if line.contains("connect down") { return "not connected" }
            if let start = intField(line, key: "uptimeStart=") {
                let secs = max(0, nowUnix - start)
                return durationLabel(secs)
            }
        }
        return "not connected"
    }

    /// Reconnect count for the readout's `reconnectCount` id: the highest `reconnect n=<count>` seen in
    /// the tail this session (the reconnect-churn emitter increments it on each involuntary reconnect).
    /// 0 when no reconnect line is present.
    public static func reconnectCount(taggedTail: [String]) -> Int {
        var maxN = 0
        for line in taggedTail where line.contains("reconnect ") {
            if let n = intField(line, key: "n=") { maxN = max(maxN, n) }
        }
        return maxN
    }

    /// Last offload result for the readout's `lastOffloadResult` id: the most recent "offload result=<...>"
    /// fragment the offload-progress emitter writes (e.g. "complete rows=42 nights=2", "empty (console
    /// only)", "stalled (idle timeout)"). nil when no offload has finished this session.
    public static func lastOffloadResult(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "offload result=") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }

    /// Parse a `key=<int>` field out of a line (the value runs up to the next space). nil when absent or
    /// non-numeric.
    static func intField(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let token = line[r.upperBound...].prefix { $0 != " " }
        return Int(token)
    }

    /// Short "Xm Ys" / "Xs" / "Xh Ym" duration label for the uptime readout.
    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
