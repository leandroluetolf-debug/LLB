import SwiftUI
import StrandDesign

// MARK: - Scoring guide
//
// "So funktionieren deine Werte" — the one honest explainer for LLB's three daily scores
// (Charge, Effort, Rest) and the confidence labels. Presented as a sheet, mirroring
// WhatsNewView's presentation + dismiss + layout idiom: a fixed header with a close
// button, a scrollable column of cards, and a "Verstanden" footer. Reachable from
// Settings → About, the ⓘ on each Today score, and the one-time first-run card.
//
// All copy here is the single approved source of truth, shared verbatim across
// macOS / iOS / Android. Each score section is tinted with the SAME Reset accent the
// rest of the app uses for that score's hero ring (Charge = green, Effort = blue
// accent, Rest = restColor slate), so a glance maps a section to its Today ring.

/// The three score sections the guide can deep-link to. The raw value is used as the
/// ScrollViewReader anchor id. The Android port mirrors these case names exactly.
enum ScoreSection: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest

    var id: String { rawValue }

    /// The accent each section uses — the SAME Reset score token its Today hero ring draws with, so a
    /// section reads as that score's colour. No gold / strain / sleep-purple: Charge = chargeColor green,
    /// Effort = effortColor blue accent, Rest = restColor slate (Design Reset, 2026-06-23).
    var accent: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor     // Charge hero ring — green
        case .effort: return StrandPalette.effortColor     // Effort hero ring — blue accent
        case .rest:   return StrandPalette.restColor       // Rest hero ring — slate
        }
    }

    /// A representative sample fraction (0–1) for the section's illustrative gauge — a
    /// "what a strong day looks like" reading, purely decorative in the guide.
    var sampleFraction: Double {
        switch self {
        case .charge: return 0.82
        case .effort: return 0.64
        case .rest:   return 0.88
        }
    }

    /// The number shown inside the sample gauge (the 0–100 score the fraction maps to).
    var sampleNumber: String {
        "\(Int((sampleFraction * 100).rounded()))"
    }

    /// The SF Symbol for the section header (heart/spark · flame · moon).
    var icon: String {
        switch self {
        case .charge: return "heart.circle.fill"
        case .effort: return "flame.fill"
        case .rest:   return "moon.stars.fill"
        }
    }

    /// Localized display name for the section (the raw value stays the stable anchor id).
    var displayName: String {
        switch self {
        case .charge: return String(localized: "Charge")
        case .effort: return String(localized: "Effort")
        case .rest:   return String(localized: "Rest")
        }
    }
}

struct ScoringGuideView: View {
    /// When set, the guide scrolls to (and briefly highlights) this section on appear —
    /// used by the ⓘ affordances on the Today screen so each opens at its own score.
    var initialSection: ScoreSection? = nil
    let onClose: () -> Void

    /// Drives the brief highlight pulse on the deep-linked section.
    @State private var highlighted: ScoreSection? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
                // Design Reset: a FLAT opaque WHOOP-grey title surface — no scenic hero, no bloom, no
                // domain tint. The header reads as a clean raised card edge, matching the Today look.
                .background(StrandPalette.surfaceRaised)
            Divider().overlay(StrandPalette.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        introCard
                        scoreCard(.charge,
                                  headline: String(localized: "Charge: Wie erholt bist du?"),
                                  body: String(localized: "Angeführt von deiner Herzfrequenzvariabilität (HRV) im Vergleich zu deiner persönlichen Baseline, plus Ruhepuls, Rest der letzten Nacht, Atemfrequenz und einem Hauttemperatur-Signal (früher Hinweis auf Krankheit oder Überlastung). Höhere HRV gegenüber deiner Baseline bedeutet mehr Charge. LLB braucht ein paar Nächte, um deine Baseline zu lernen. Bis dahin siehst du „Kalibriert“."),
                                  vsWhoop: String(localized: "Gleiche Grundidee wie WHOOPs Erholung-% (HRV-geführte Recovery), aber Gewichtung und Baseline-Mathe sind unsere eigenen und offen dokumentiert."))
                        scoreCard(.effort,
                                  headline: String(localized: "Effort: Wie hart hat dein Herz gearbeitet?"),
                                  body: String(localized: "Deine kardiovaskuläre Belastung. LLB wandelt jede Sekunde Herzfrequenz in einen Trainingsimpuls um (Herzfrequenz-Reserve-Zonen nach Karvonen), gewichtet Zeit in härteren Zonen stärker (Edwards / Banister) und legt sie auf eine logarithmische 0–100-Skala — leichte Tage liegen niedrig, ein Maximal-Tag nähert sich 100, was wirklich selten bleibt. Ein langer Spaziergang mit wenig Cardio zählt trotzdem über eine Schritte-/Aktivenergie-Untergrenze."),
                                  vsWhoop: String(localized: "Gleiche Idee der kardiovaskulären Belastung wie WHOOPs Day Strain (0–21). Wir haben die Skala von 21 auf 100 gestreckt, damit alle drei Werte dieselbe Skala teilen. Die Stufen sind gleich geblieben — eine 100 ist so selten wie früher 21,0."))
                        scoreCard(.rest,
                                  headline: String(localized: "Rest: Wie erholsam war dein Schlaf?"),
                                  body: String(localized: "Eine Mischung aus Schlafdauer gegenüber deinem persönlichen Bedarf (der größte Faktor), Effizienz (Schlaf vs. im Bett), wie viel erholsam war (Tief- + REM-Schlaf) und wie gleichmäßig Schlaf- und Wachzeiten sind."),
                                  vsWhoop: String(localized: "Ähnlich im Geist wie WHOOPs Schlaf-Performance-%; unser Verbundwert ist unser eigener."))
                        confidenceCard
                        footerNote
                    }
                    .padding(20)
                }
                .onAppear { jump(to: initialSection, using: proxy) }
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        // Same sizing split as WhatsNewView: a fixed window on macOS, fill the presented
        // sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long explainer scroll → open full-height, with a grabber for swipe-to-dismiss.
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DEINE TAGESWERTE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("So funktionieren deine Werte").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Charge · Effort · Rest").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schließen")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Verstanden").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Cards

    private var introCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("DIE DREI WERTE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("LLB gibt dir drei Tageswerte (Charge, Effort und Rest), jeweils auf einer 0–100-Skala. Sie entstehen aus den Rohsignalen deines Bands mit veröffentlichter, peer-reviewter Sportwissenschaft — vollständig auf deinem Gerät. Es sind NICHT WHOOPs Werte: Wir haben WHOOPs private Algorithmen nicht und tun nicht so. Sie beantworten dieselben drei Fragen mit offener Wissenschaft, folgen WHOOP meist in der Richtung, stimmen aber nicht Zahl für Zahl überein. Und genau das ist der Punkt.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The three accents as a quick legend, echoing the section colours below.
                HStack(spacing: 16) {
                    legendDot(.charge, String(localized: "Charge"))
                    legendDot(.effort, String(localized: "Effort"))
                    legendDot(.rest, String(localized: "Rest"))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendDot(_ section: ScoreSection, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(section.accent).frame(width: 8, height: 8)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// One colour-accented score section: a FLAT WHOOP-grey card (faintly washed with the section's Reset
    /// accent) carrying a clean sample ring of that score beside an accent-tinted headline, the body, and
    /// an italic "vs WHOOP" line set off by a hairline rule. The ring is illustrative — a "what a strong
    /// day reads like" preview in the section's own colour — so a glance maps a card to its Today ring.
    /// Design Reset: a flat GlowRing (no bloom) replaces the old BevelGauge; the accent is a Reset score
    /// token, never gold / strain / sleep-purple.
    private func scoreCard(_ section: ScoreSection, headline: String, body: String, vsWhoop: String) -> some View {
        NoopCard(tint: section.accent) {
            VStack(alignment: .leading, spacing: 14) {
                // Header row — the flat sample ring sits beside the accent icon + headline.
                HStack(alignment: .center, spacing: 14) {
                    sampleRing(section)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(section.accent)
                                .accessibilityHidden(true)
                            Text(section.displayName)
                                .font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .textCase(.uppercase)
                                .foregroundStyle(section.accent)
                        }
                        Text(headline).font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text(body)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                HStack(alignment: .top, spacing: 8) {
                    Text("vs WHOOP").font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(section.accent)
                        .padding(.top, 1)
                    Text(vsWhoop)
                        .font(StrandFont.footnote)
                        .italic()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Deep-link highlight: a brief accent-tinted ring when arrived at via an ⓘ.
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(section.accent, lineWidth: 2)
                .opacity(highlighted == section ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.35), value: highlighted)
        .id(section.id)
    }

    /// The flat illustrative ring for a score section — a clean GlowRing (Design Reset: solid crisp arc,
    /// NO bloom) in the section's Reset accent, with the score name as a small caption below, matching the
    /// Today hero rings. Decorative ("what a strong day looks like"), so it's hidden from VoiceOver by the
    /// caller. Replaces the old per-section BevelGauge(bloomActive: true).
    private func sampleRing(_ section: ScoreSection) -> some View {
        VStack(spacing: 5) {
            GlowRing(
                fraction: section.sampleFraction,
                value: section.sampleFraction * 100,
                format: { "\(Int($0.rounded()))" },
                color: section.accent,
                diameter: 76,
                lineWidth: 8
            )
            Text(section.displayName)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var confidenceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wie sicher ist LLB?  ·  Stabil · Aufbauend · Kalibriert")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // The three labels as the same pills used elsewhere, in their honest order.
                HStack(spacing: 8) {
                    StatePill("Stabil", tone: .positive, showsDot: true)
                    StatePill("Aufbauend", tone: .warning, showsDot: true)
                    StatePill("Kalibriert", tone: .neutral, showsDot: true)
                }
                Text("Jeder Wert trägt ein kleines Ehrlichkeitsetikett. Kalibriert heißt: LLB lernt noch deine Baseline oder hat noch nicht genug Daten. Aufbauend heißt: genug für eine Anzeige, aber noch dünn. Stabil heißt: volle Eingaben vorhanden. Wenn LLB einen Wert nicht ehrlich berechnen kann, zeigt es nichts statt einer erfundenen Zahl.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerNote: some View {
        Text("Das sind unabhängige Näherungen von einem Consumer-Band, aufgebaut auf offener Wissenschaft: kein medizinischer Rat und keine offiziellen WHOOP-Werte.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Deep-link

    /// Scroll to the requested section and pulse its highlight, then fade it.
    private func jump(to section: ScoreSection?, using proxy: ScrollViewProxy) {
        guard let section else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(section.id, anchor: .top)
            }
            highlighted = section
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if highlighted == section { highlighted = nil }
            }
        }
    }
}

#if DEBUG
#Preview("Bewertungsleitfaden") {
    ScoringGuideView(initialSection: .effort, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
