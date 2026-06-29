import SwiftUI
import StrandDesign
import WhoopStore
import OuraProtocol

// MARK: - Devices
//
// Pair and manage the bands NOOP reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over `DeviceRegistry` (the Phase 1A/1B data layer): every mutation
// goes through a registry op, and the `SourceCoordinator` (already wired in AppModel) reacts to the
// active-device change — so this view never touches BLEManager or the WHOOP path directly.
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    // PERF: this OUTER view does NOT observe `LiveState`. It only branches on `model.deviceRegistry`
    // becoming non-nil and hands off to `DevicesContent`, which owns its own `@EnvironmentObject live`
    // (the live battery / "Active · Live" badge live there). Observing `live` here would re-render the
    // whole screen on every ~1 Hz strap tick for no visible change — `live` is still in the environment
    // for `DevicesContent` and the Add-device wizard, so nothing downstream loses its live readout.

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "Pair and manage the bands NOOP reads from.") {
            if let registry = model.deviceRegistry {
                DevicesContent(registry: registry)
            } else {
                // The registry is built once the on-device store opens (a beat after launch). Show a
                // calm pending note rather than an empty screen in that brief window.
                DataPendingNote(
                    title: "Getting your devices ready",
                    message: "NOOP is opening your on-device data. Your paired bands will appear here in a moment.",
                    symbol: "badge.plus.radiowaves.right")
            }
        }
    }
}

// MARK: - Content (registry resolved)

/// The screen body once `DeviceRegistry` exists. Split out so it can observe the registry's
/// `@Published devices` / `activeDeviceId` directly — the parent only observes `model.deviceRegistry`
/// becoming non-nil.
private struct DevicesContent: View {
    @ObservedObject var registry: DeviceRegistry
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    // Sheets / alerts
    @State private var showAddWizard = false
    @State private var switchTarget: PairedDevice?
    @State private var renameTarget: PairedDevice?
    @State private var renameDraft = ""
    @State private var removeTarget: PairedDevice?
    @State private var deleteDataTarget: PairedDevice?
    /// After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    @State private var pickNewActive = false

    private var activeDevices: [PairedDevice] { registry.devices.filter { $0.status != .archived } }
    private var removedDevices: [PairedDevice] { registry.devices.filter { $0.status == .archived } }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            ForEach(Array(activeDevices.enumerated()), id: \.element.id) { idx, device in
                DeviceCard(
                    device: device,
                    isActive: device.status == .active,
                    isLiveConnected: device.status == .active && live.connected,
                    // The live battery belongs to whichever device is ACTIVE + connected (the WHOOP, a
                    // generic strap, or an FTMS machine all funnel into live.batteryPct). nil otherwise.
                    liveBatteryPct: (device.status == .active && live.connected) ? live.batteryPct.map { Int($0.rounded()) } : nil,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: { removeTarget = device })
                    .staggeredAppear(index: idx)
            }

            addButton
                .staggeredAppear(index: activeDevices.count)

            if !removedDevices.isEmpty { removedSection }

            whoopFirstFooter
        }
        // Add a device — guided, branching wizard (asks the device TYPE first, then runs the right
        // scan/register path: WHOOP present-scan for WHOOP families, StandardHRSource for HR straps).
        .sheet(isPresented: $showAddWizard) {
            AddDeviceWizard(live: live) { showAddWizard = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        // Switch confirm
        .alert("Make this your active strap?",
               isPresented: Binding(get: { switchTarget != nil },
                                    set: { if !$0 { switchTarget = nil } }),
               presenting: switchTarget) { device in
            Button("Cancel", role: .cancel) { switchTarget = nil }
            Button("Make active") {
                registry.setActive(device.id)
                switchTarget = nil
            }
        } message: { device in
            Text("Make \(device.displayName) your active strap? From now on it provides your live data. \(currentActiveName)'s history stays exactly as it is — only new days come from \(device.displayName).")
        }
        // Rename
        .alert("Rename device",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { device in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                registry.rename(device.id, to: renameDraft)
                renameTarget = nil
            }
        } message: { device in
            Text("Give \(device.brand) \(device.model) a name you'll recognise.")
        }
        // Remove confirm
        .alert("Remove this device?",
               isPresented: Binding(get: { removeTarget != nil },
                                    set: { if !$0 { removeTarget = nil } }),
               presenting: removeTarget) { device in
            Button("Cancel", role: .cancel) { removeTarget = nil }
            Button("Remove", role: .destructive) { confirmRemove(device) }
        } message: { device in
            Text("Remove \(device.displayName)? NOOP will stop connecting to it. Its recorded data is kept and you can re-add it any time.")
        }
        // Second, strongly-worded delete-data confirm (reached from the Remove card's secondary control)
        .alert("Delete all of this device's data?",
               isPresented: Binding(get: { deleteDataTarget != nil },
                                    set: { if !$0 { deleteDataTarget = nil } }),
               presenting: deleteDataTarget) { device in
            Button("Cancel", role: .cancel) { deleteDataTarget = nil }
            Button("Delete data", role: .destructive) {
                registry.deleteDeviceData(device.id)
                deleteDataTarget = nil
            }
        } message: { device in
            Text("This permanently deletes all data recorded from \(device.displayName). This can't be undone.")
        }
        // After removing the active device, offer to pick a new active one (if any remain).
        .confirmationDialog("Pick a new active strap",
                            isPresented: $pickNewActive,
                            titleVisibility: .visible) {
            ForEach(activeDevices) { device in
                Button(device.displayName) { registry.setActive(device.id) }
            }
            Button("Leave none active", role: .cancel) { }
        } message: {
            Text("You removed your active strap. Choose which paired band provides your live data, or leave none active and pair one later.")
        }
    }

    // MARK: Pieces

    private var addButton: some View {
        NoopButton("Add a device", systemImage: "plus", kind: .primary, fullWidth: true) {
            showAddWizard = true
        }
        .accessibilityLabel("Add a device")
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            Text("Removed").strandOverline()
            ForEach(removedDevices) { device in
                DeviceCard(
                    device: device,
                    isActive: false,
                    isLiveConnected: false,
                    dimmed: true,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: nil,
                    onReAdd: { registry.setActive(device.id) },
                    onDeleteData: { deleteDataTarget = device })
            }
        }
    }

    private var whoopFirstFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps are an early, in-development addition — they stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Logic

    private var currentActiveName: String {
        registry.devices.first(where: { $0.status == .active })?.displayName ?? "Your current strap"
    }

    /// Archive the device, then — if it was the active one and other non-archived devices remain —
    /// prompt for a new active device. The active row is demoted to `.paired` by the registry's reload,
    /// so the dialog's choices come from the still-paired devices.
    private func confirmRemove(_ device: PairedDevice) {
        let wasActive = device.status == .active
        // #78: actually RELEASE the BLE link, not just archive the registry row — otherwise NOOP keeps
        // re-grabbing the strap (reconnect timer + targeted-connect pin + iOS state restoration), holding
        // it connected so it can never enter pairing mode to be re-paired.
        model.ble.forgetDevice(device.peripheralId)
        registry.archive(device.id)
        removeTarget = nil
        if wasActive {
            // Other paired devices left → ask which becomes active; otherwise no active device remains.
            if !activeDevices.isEmpty {
                pickNewActive = true
            }
        }
    }
}

// MARK: - Device card

/// One paired device as a card: name, brand/model, capabilities line, a state pill, last-seen, and a
/// per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries an "Active" pill.
private struct DeviceCard: View {
    let device: PairedDevice
    let isActive: Bool
    let isLiveConnected: Bool
    /// The active+connected device's live battery percent (0–100), surfaced on the card the same way
    /// for WHOOP, a generic strap, or an FTMS machine. nil when not the active/connected device or
    /// the source hasn't reported a battery (e.g. a strap/machine without the 0x180F service).
    var liveBatteryPct: Int? = nil
    var dimmed: Bool = false
    var onMakeActive: () -> Void
    var onRename: () -> Void
    var onRemove: (() -> Void)?
    /// Removed-section affordances (re-add as active / delete its data).
    var onReAdd: (() -> Void)? = nil
    var onDeleteData: (() -> Void)? = nil

    var body: some View {
        StrandCard(padding: 18, tint: isActive ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: icon)
                        .font(StrandFont.title2)
                        .foregroundStyle(isActive ? StrandPalette.accent : StrandPalette.textSecondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.displayName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(profile.displayModel)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    // Locally-adopted Oura is Beta: a non-dot Beta chip sits beside the usual state pill.
                    if device.sourceKind == .oura {
                        StatePill("Beta", tone: .warning, showsDot: false)
                    }
                    statePill
                }

                // Honest local-takeover state row for an adopted Oura ring that is paired but not the
                // active+connected source right now. States the single-owner reality plainly (if the ring
                // was reset again or re-claimed in the Oura app, NOOP no longer owns it) without faking a
                // live reading. Suppressed for the active+connected ring and for removed rings.
                if device.sourceKind == .oura && !isLiveConnected && device.status == .paired {
                    ouraLocalStateNote
                }

                // What this device CAPTURES — honest, per-model (not the generic stored set, which would
                // mislabel e.g. a "Blood oxygen" chip when no SpO₂ % ever comes off the strap).
                capabilityRow(symbol: "waveform.path.ecg", text: profile.captures,
                              tint: StrandPalette.textSecondary)
                // What NOOP USES it for — the scores/screens this device drives.
                capabilityRow(symbol: "bolt.fill", text: profile.powers,
                              tint: StrandPalette.textSecondary)
                // Honest footnote: the "*" estimates + the SpO₂/steps caveats.
                if !profile.footnote.isEmpty {
                    Text(profile.footnote)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(lastSeenLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    // Live battery for the active+connected device — same surface for WHOOP / strap / FTMS.
                    if let pct = liveBatteryPct {
                        Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Label("\(pct)%", systemImage: batterySymbol(pct))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .labelStyle(.titleAndIcon)
                            .accessibilityLabel("Battery \(pct) percent")
                    }
                    Spacer()
                    actionsMenu
                }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    private var statePill: some View {
        Group {
            if device.status == .archived {
                StatePill("Removed", tone: .neutral, showsDot: false)
            } else if isActive {
                StatePill(isLiveConnected ? "Active · Live" : "Active",
                          tone: .positive, pulsing: isLiveConnected)
            } else {
                StatePill("Paired", tone: .neutral)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            if device.status == .archived {
                if let onReAdd {
                    Button { onReAdd() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onDeleteData {
                    Divider()
                    Button(role: .destructive) { onDeleteData() } label: {
                        Label("Delete this device's data…", systemImage: "trash")
                    }
                }
            } else {
                if !isActive {
                    Button { onMakeActive() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onRemove {
                    Divider()
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Device actions for \(device.displayName)")
    }

    /// SF Symbol for the device: WHOOP keeps the band glyph; an FTMS machine reads as gym equipment;
    /// an Apple Watch reads as a watch; generic straps read as a heart-rate strap.
    private var icon: String {
        if device.sourceKind == .ftms { return "figure.run.treadmill" }
        if device.sourceKind == .huami { return "waveform.path.ecg.rectangle" }
        if device.sourceKind == .liveAppleWatch { return "applewatch" }
        if device.sourceKind == .oura { return "circle.circle" }
        return SourceCoordinator.isWhoop(device) ? "applewatch.side.right" : "heart.circle"
    }

    /// The honest, per-model capability + function summary for this device's card.
    private var profile: DeviceCapabilityProfile { .make(for: device) }

    /// One icon-prefixed info row (captures / powers), matching the card's caption style.
    private func capabilityRow(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastSeenLine: String {
        if device.status == .archived { return "Removed · data kept" }
        if isLiveConnected { return "Connected now" }
        return "Last seen \(relativeAgo(TimeInterval(device.lastSeenAt)))"
    }

    /// Honest paired-but-not-connected note for a locally-adopted Oura ring. Amber heads-up, no fabricated
    /// reading: re-states the single-owner reality so the user understands why a re-reset / Oura re-claim
    /// would break NOOP's ownership.
    private var ouraLocalStateNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("Paired locally. NOOP owns this ring while it holds the key. If you reset it again or set it up in the Oura app, NOOP no longer owns it and you would re-add it to take it over.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A battery SF Symbol matching the charge band (mirrors the menu-bar battery glyph buckets).
    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
}

// MARK: - Capability profile

/// Honest, per-model summary of what a device captures and what NOOP uses it for — shown on its card.
///
/// Derived from brand/model/sourceKind, NOT from the stored capability `Set`. The stored set is generic
/// across WHOOP models (it would render an identical "Heart rate · HRV · Blood oxygen · Skin temp · …"
/// line for a 4.0 and a 5/MG alike) and it mislabels: no SpO₂ **percentage** ever comes off any WHOOP
/// strap (raw red/IR only — a real % exists only from a WHOOP CSV / Apple Health import), skin temp is a
/// nightly ±°C sleep deviation rather than a live reading, steps are 5/MG-only and a raw motion count,
/// and Charge/Effort/Rest are NOOP-derived scores. Verdicts are source-verified against the decode +
/// scoring paths (the device-capability audit). `*` in a label = an on-device estimate, not a raw sensor.
struct DeviceCapabilityProfile {
    let displayModel: String   // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    let captures: String       // "·"-joined honest capture labels for THIS model
    let powers: String         // the NOOP scores / screens this device drives
    let footnote: String       // one short honest caveat line ("*" estimates + the SpO₂/steps notes)

    static func make(for d: PairedDevice) -> DeviceCapabilityProfile {
        // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
        // live-workout path. Honest — we surface the machine's metrics + HR live; the session is
        // Effort-scored only when the machine actually reports heart rate.
        if d.sourceKind == .ftms {
            return DeviceCapabilityProfile(
                displayModel: "Gym equipment (FTMS)",
                captures: "Speed · Cadence · Power · Distance · Energy · Heart rate (if the machine sends it)",
                powers: "Records a live machine workout — Effort-scored from HR when the machine reports it",
                footnote: "Live machine data over Bluetooth FTMS. No sleep, recovery, skin temp or SpO₂. Effort needs the machine's heart rate; without it the session logs the machine metrics only.")
        }
        // EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band): best-effort live HR only, honest about it.
        if d.sourceKind == .huami {
            return DeviceCapabilityProfile(
                displayModel: "\(d.brand) (experimental)",
                captures: "Heart rate (live, best-effort)",
                powers: "Powers the live console + Effort — no Charge, Rest or Sleep",
                footnote: "Experimental: live heart rate where the band exposes it. Some bands need a pairing we can't do yet — NOOP will say so honestly and never show a made-up number. No sleep, recovery, skin temp, SpO₂ or steps.")
        }
        // EXPERIMENTAL locally-adopted Oura ring (gen 3/4/5). The gen is carried on `model` ("Oura Ring
        // 3/4/5") and recovered with OuraRingGen.from(model:). NOOP reads the ring's OWN raw signals + open
        // HRV/sleep-phase tags and computes its own Charge/Effort/Rest; it NEVER reads Oura's encrypted
        // Readiness/Sleep scores, and claims NO absolute SpO₂ %. Estimates carry "*"; a signal it can't read
        // stays "-". Per-gen copy and the canonical Beta caveat (spec
        // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md s3/s4).
        if d.sourceKind == .oura {
            let gen = OuraRingGen.from(model: d.model)
            // gen3/4 are verified-shape; gen5 ("newer") carries the least-proven caveat.
            let newer = (gen == .gen5)
            let captures = newer
                ? "Heart rate* · HRV* · Sleep* · Resting HR* · Skin temp* · Battery*"
                : "Heart rate · HRV* · Sleep · Resting HR · Skin temp* · Battery"
            let powers = newer
                ? "Powers Effort now; Charge and Rest once enough nights and decode are confirmed"
                : "Powers Charge, Effort, Rest and Sleep"
            return DeviceCapabilityProfile(
                displayModel: "\(gen.displayName) (Beta)",
                captures: captures,
                powers: powers,
                footnote: "Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, and HRV needs you to be still. No Oura Readiness or SpO₂ percentage comes off the ring (import an Oura file for those).")
        }
        // Apple Watch (live HealthKit source). UNLIKE the WHOOP/strap branches, the watch's stored
        // capability `Set` is already the honest per-model trim (AppleWatchDevice only adds a metric
        // once real data for it arrives), so we read the labels straight off it. An older watch with
        // no SpO₂/wrist-temp samples simply won't list them. Recovery is the calibrating-by-design
        // score (~a week of nights), so the footnote sets that expectation rather than over-promising.
        if d.sourceKind == .liveAppleWatch {
            let labels: [(Metric, String)] = [
                (.hr, "Heart rate"), (.hrv, "HRV"), (.sleep, "Sleep"),
                (.steps, "Steps"), (.spo2, "Blood oxygen"), (.skinTemp, "Wrist temp"),
            ]
            let captures = labels.filter { d.capabilities.contains($0.0) }.map { $0.1 }.joined(separator: " · ")
            return DeviceCapabilityProfile(
                displayModel: "Apple Watch",
                captures: captures.isEmpty ? "Calibrating, no data yet" : captures,
                powers: "Powers Rest, Effort, Fitness Age and steps, plus Charge once recovery calibrates",
                footnote: "Computed live from your Apple Watch via Health. Recovery needs about a week of nights to calibrate, and every watch-derived score is labelled with its confidence. Only the metrics your watch actually records are listed above.")
        }
        // Generic heart-rate strap: live HR + R-R only; drives the live console + Effort, nothing nightly.
        // (Same WHOOP test as SourceCoordinator.isWhoop, inlined so this stays nonisolated.)
        let isWhoop = d.id == "my-whoop" || d.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        guard isWhoop else {
            return DeviceCapabilityProfile(
                displayModel: "Heart-rate strap",
                captures: "Heart rate · HRV (live)* · Strain",
                powers: "Powers the live console + Effort — no Charge, Rest or Sleep",
                footnote: "Live HR + R-R only · no sleep, recovery, skin temp, SpO₂, steps or battery (those are WHOOP-only).")
        }
        let whoopPowers = "Powers Charge, Effort, Rest, Sleep + Health Monitor"
        let model = d.model.lowercased()
        // WHOOP 5.0 / MG — adds a (raw) step count the 4.0 can't read over BLE.
        if model.contains("5") || model.contains("mg") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 5.0 / MG",
                captures: "Heart rate · HRV · Skin temp* · Resp rate* · Steps* · Sleep · Strain · Battery",
                powers: whoopPowers,
                footnote: "* on-device estimate — skin temp is a nightly ±°C deviation, steps are a raw motion count (#78). No SpO₂ % off the strap; import a WHOOP CSV for a real %.")
        }
        // WHOOP 4.0 — NOOP's primary band; no steps over BLE.
        if model.contains("4") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 4.0",
                captures: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery",
                powers: whoopPowers,
                footnote: "* on-device estimate — skin temp is a nightly ±°C deviation (firmware-dependent); no steps over BLE on a 4.0. No SpO₂ % off the strap; import a WHOOP CSV for a real %.")
        }
        // Legacy / unknown WHOOP (the seeded device, model just "WHOOP") — show only the common-to-all set.
        return DeviceCapabilityProfile(
            displayModel: "WHOOP",
            captures: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery",
            powers: whoopPowers,
            footnote: "Exact model unknown — shows what every WHOOP can do. * on-device estimate · no SpO₂ % off the strap (import a WHOOP CSV for that).")
    }
}

// MARK: - Signal indicator

/// A four-bar Wi-Fi-style signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is
/// stronger. Buckets are coarse on purpose — a precise dBm readout would be noise to the user.
/// Internal (not private) so the Add-a-device wizard reuses the same indicator.
struct SignalBars: View {
    let rssi: Int

    static func level(for rssi: Int) -> Int {
        switch rssi {
        case (-55)...:    return 4   // very strong
        case (-67)...:    return 3
        case (-80)...:    return 2
        case (-90)...:    return 1
        default:          return 0
        }
    }

    var body: some View {
        let level = Self.level(for: rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < level ? StrandPalette.accent : StrandPalette.hairlineStrong)
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .frame(width: 22, height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Capability catalog (DEBUG render harness)

#if DEBUG
/// DEBUG-only: one DeviceCard per capability-profile kind so the honest per-model display can be
/// screenshotted deterministically (`--demo-screen devicescatalog`). Same file as `DeviceCard` /
/// `DeviceCapabilityProfile` so it can reach them. Stripped from Release.
struct DeviceCardCatalog: View {
    private static let whoopCaps: Set<Metric> = [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad]

    private static func dev(_ id: String, _ brand: String, _ model: String,
                            _ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: model, nickname: nil, peripheralId: nil,
                     sourceKind: .liveBLE, capabilities: caps, status: .paired,
                     addedAt: 0, lastSeenAt: 0)
    }

    private static func watch(_ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch", nickname: nil,
                     peripheralId: nil, sourceKind: .liveAppleWatch, capabilities: caps,
                     status: .paired, addedAt: 0, lastSeenAt: 0)
    }

    /// A locally-adopted Oura ring (sourceKind `.oura`), built with mock data so the honest per-gen Beta
    /// card renders deterministically WITHOUT a ring. `model` carries the gen ("Oura Ring 3/4/5").
    static func oura(_ model: String, status: DeviceStatus = .paired) -> PairedDevice {
        PairedDevice(id: "oura-demo-\(model)", brand: "Oura", model: model, nickname: nil,
                     peripheralId: "00000000-0000-0000-0000-0000000000aa", sourceKind: .oura,
                     capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep],
                     status: status, addedAt: 0, lastSeenAt: 0)
    }

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "What each band captures — and what NOOP uses it for.") {
            VStack(spacing: NoopMetrics.gap) {
                DeviceCard(device: Self.dev("whoop-4d", "WHOOP", "4.0", Self.whoopCaps),
                           isActive: true, isLiveConnected: true,
                           onMakeActive: {}, onRename: {}, onRemove: nil)
                DeviceCard(device: Self.dev("whoop-5d", "WHOOP", "5.0 MG",
                                            Self.whoopCaps.union([.steps])),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                DeviceCard(device: Self.dev("strap-d", "Polar", "H10", [.hr, .hrv]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Apple Watch, with an older-model trimmed set (no SpO₂ / wrist temp) so the honest
                // capability read renders deterministically alongside the straps.
                DeviceCard(device: Self.watch([.hr, .hrv, .sleep, .steps]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Locally-adopted Oura ring (Beta): per-gen honest capability copy + the Beta chip + the
                // paired-but-not-connected local-state note, all without a ring on-wrist.
                DeviceCard(device: Self.oura("Oura Ring 3"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}

/// DEBUG-only: just the locally-adopted Oura device card, active + connected, so `--demo-screen ouradevice`
/// can screenshot the Beta Oura card (battery + "Active · Live") WITHOUT a ring. Same file as `DeviceCard`
/// so it can reach it. Stripped from Release.
struct OuraDeviceDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "A locally-adopted Oura ring, in beta.") {
            VStack(spacing: NoopMetrics.gap) {
                // Active + connected so the card shows "Active · Live" + a live battery readout.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 3"),
                           isActive: true, isLiveConnected: true, liveBatteryPct: 71,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // A second, paired-but-not-connected gen-4 ring so the honest local-state note + per-gen
                // copy render in the same shot.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 4"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
#Preview("Devices") {
    let model = AppModel()
    return DevicesView()
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
