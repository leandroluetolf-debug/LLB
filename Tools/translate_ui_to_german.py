#!/usr/bin/env python3
"""Replace common English UI string literals with German in LLB sources.

Only touches quoted string contents (not identifiers). Longest phrases first.
Skips URLs, package names, and pure technical tokens.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Longest-first phrase map (UI / coach / settings). Brand names WHOOP, LLB, HRV, SpO₂ stay.
PHRASES: list[tuple[str, str]] = [
    ("Let the coach use my data", "Coach darf meine Daten nutzen"),
    ("Check for updates", "Nach Updates suchen"),
    ("Checking…", "Prüfe…"),
    ("Couldn't check. Try again.", "Prüfung fehlgeschlagen. Bitte erneut versuchen."),
    ("You're on the latest", "Du bist auf dem neuesten Stand"),
    ("Version", "Version"),
    ("is available", "ist verfügbar"),
    ("Download", "Herunterladen"),
    ("What's new", "Neuigkeiten"),
    ("How LLB works", "So funktioniert LLB"),
    ("How your scores work", "So funktionieren deine Werte"),
    ("Scoring guide", "Bewertungsleitfaden"),
    ("Key Metrics", "Kennzahlen"),
    ("Your cards", "Deine Karten"),
    ("Heart Rate", "Herzfrequenz"),
    ("Beats per minute", "Schläge pro Minute"),
    ("Settings", "Einstellungen"),
    ("Devices", "Geräte"),
    ("Data Sources", "Datenquellen"),
    ("Backup & Sync", "Backup & Sync"),
    ("Notifications", "Mitteilungen"),
    ("Automations", "Automationen"),
    ("Test Centre", "Testcenter"),
    ("Support", "Hilfe"),
    ("About", "Über"),
    ("Profile", "Profil"),
    ("Appearance", "Darstellung"),
    ("Theme", "Design"),
    ("System", "System"),
    ("Light", "Hell"),
    ("Dark", "Dunkel"),
    ("Today", "Heute"),
    ("Yesterday", "Gestern"),
    ("Sleep", "Schlaf"),
    ("Workouts", "Workouts"),
    ("Trends", "Trends"),
    ("Coach", "Coach"),
    ("Insights", "Einblicke"),
    ("Health", "Gesundheit"),
    ("Stress", "Stress"),
    ("Live", "Live"),
    ("Breathe", "Atmen"),
    ("Intervals", "Intervalle"),
    ("Compare", "Vergleichen"),
    ("Explore", "Entdecken"),
    ("Hydration", "Flüssigkeit"),
    ("Vital Signs", "Vitalwerte"),
    ("Lab Book", "Laborbuch"),
    ("Rhythm", "Rhythmus"),
    ("Alarms", "Wecker"),
    ("More", "Mehr"),
    ("Edit", "Bearbeiten"),
    ("Cancel", "Abbrechen"),
    ("Save", "Speichern"),
    ("Delete", "Löschen"),
    ("Close", "Schließen"),
    ("Done", "Fertig"),
    ("Next", "Weiter"),
    ("Back", "Zurück"),
    ("Continue", "Weiter"),
    ("Skip", "Überspringen"),
    ("Enable", "Aktivieren"),
    ("Disable", "Deaktivieren"),
    ("On", "An"),
    ("Off", "Aus"),
    ("Connected", "Verbunden"),
    ("Disconnected", "Getrennt"),
    ("Connecting…", "Verbinde…"),
    ("Searching…", "Suche…"),
    ("Re-scan", "Erneut scannen"),
    ("Disconnect", "Trennen"),
    ("Pair", "Koppeln"),
    ("Battery", "Akku"),
    ("Charging", "Lädt"),
    ("No data", "Keine Daten"),
    ("No Data", "Keine Daten"),
    ("Calibrating", "Kalibriert"),
    ("calibrating", "kalibriert"),
    ("Import", "Importieren"),
    ("Export", "Exportieren"),
    ("Restore", "Wiederherstellen"),
    ("Reset", "Zurücksetzen"),
    ("Reset to default", "Standard wiederherstellen"),
    ("Add your own API key first to use the coach.", "Hinterlege zuerst deinen eigenen API-Schlüssel, um den Coach zu nutzen."),
    ("Type a question for the coach.", "Stelle dem Coach eine Frage."),
    ("Network problem:", "Netzwerkproblem:"),
    ("The coach is the only feature that needs the internet.", "Der Coach ist die einzige Funktion, die Internet braucht."),
    ("Today's brief", "Briefing für heute"),
    ("Got it", "Verstanden"),
    ("Open LLB", "LLB öffnen"),
    ("Open LLB to connect", "LLB öffnen zum Verbinden"),
    ("Open LLB on your iPhone to sync", "Öffne LLB auf dem iPhone zum Synchronisieren"),
    ("CUSTOMISE", "ANPASSEN"),
    ("Customise", "Anpassen"),
    ("Customize", "Anpassen"),
    ("Body", "Körper"),
    ("Data", "Daten"),
    ("App", "App"),
    ("Intelligence", "Intelligenz"),
    ("What Moves You", "Was dich bewegt"),
    ("Coupled view", "Gekoppelte Ansicht"),
    ("Your Data, Fused", "Deine Daten, vereint"),
    ("Apple Health", "Apple Health"),
    ("Start workout", "Workout starten"),
    ("Log journal", "Journal notieren"),
    ("Live HR", "Live-HF"),
    ("Resting HR", "Ruhe-HF"),
    ("Resting heart rate", "Ruhepuls"),
    ("Heart-rate variability", "Herzfrequenzvariabilität"),
    ("Heart rate variability", "Herzfrequenzvariabilität"),
    ("Respiratory rate", "Atemfrequenz"),
    ("Skin temperature", "Hauttemperatur"),
    ("Fitness age", "Fitnessalter"),
    ("Steps", "Schritte"),
    ("Calories", "Kalorien"),
    ("Weight", "Gewicht"),
    ("Charge", "Charge"),
    ("Effort", "Effort"),
    ("Rest", "Rest"),
    ("Recovery", "Erholung"),
    ("Strain", "Belastung"),
    ("Readiness", "Bereitschaft"),
    ("Building your baseline", "Basiswerte werden aufgebaut"),
    ("Live now. Your scores are building.", "Live läuft. Deine Werte bauen sich auf."),
    ("No cardio load yet.", "Noch keine Cardio-Belastung."),
    ("Strap", "Band"),
    ("WHOOP", "WHOOP"),
]

# Sort longest first
PHRASES.sort(key=lambda x: len(x[0]), reverse=True)

SKIP_IF_CONTAINS = (
    "http://", "https://", "com.", "android.", "noop.", "llb.", "my-whoop",
    "applicationId", "package ", "import ", "@/",
)

STRING_RE = re.compile(r'("(?:\\.|[^"\\])*")')


def translate_literal(s: str) -> str:
    """s includes surrounding quotes."""
    inner = s[1:-1]
    if not inner or inner.startswith("$"):
        return s
    if any(tok in inner for tok in SKIP_IF_CONTAINS):
        return s
    # Skip pure identifiers / paths
    if re.fullmatch(r"[A-Za-z0-9_./\\-]+", inner) and " " not in inner and len(inner) < 4:
        return s
    out = inner
    for en, de in PHRASES:
        if en in out:
            out = out.replace(en, de)
    if out == inner:
        return s
    return '"' + out.replace("\\", "\\\\").replace('"', '\\"') + '"' if False else '"' + out + '"'


def process_file(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return False
    if '"' not in text:
        return False

    def repl(m: re.Match[str]) -> str:
        lit = m.group(1)
        # Don't touch escaped-only or empty
        try:
            return translate_literal(lit)
        except Exception:
            return lit

    new = STRING_RE.sub(repl, text)
    # Fix over-escaped if we double-escaped — we avoided that
    if new != text:
        path.write_text(new, encoding="utf-8")
        return True
    return False


def process_xcstrings(path: Path) -> bool:
    """Ensure every string has a German localization (translate English source)."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return False
    strings = data.get("strings") or {}
    changed = False
    for key, unit in strings.items():
        if not isinstance(unit, dict):
            continue
        localizations = unit.setdefault("localizations", {})
        # Translate the key (source English) for de
        de_val = key
        for en, de in PHRASES:
            if en in de_val:
                de_val = de_val.replace(en, de)
        # If already has de, still refresh if it still looks English-heavy? Only set if missing.
        if "de" not in localizations:
            localizations["de"] = {
                "stringUnit": {"state": "translated", "value": de_val}
            }
            changed = True
        else:
            # Update existing de if it equals English key (untranslated)
            try:
                cur = localizations["de"]["stringUnit"]["value"]
            except Exception:
                cur = None
            if cur == key and de_val != key:
                localizations["de"]["stringUnit"]["value"] = de_val
                changed = True
    if changed:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return changed


def main() -> None:
    roots = [
        ROOT / "android/app/src/main/java/com/noop/ui",
        ROOT / "android/app/src/main/java/com/noop/ai",
        ROOT / "android/app/src/main/java/com/noop/update",
        ROOT / "android/app/src/main/java/com/noop/widget",
        ROOT / "Strand",
        ROOT / "StrandiOS",
        ROOT / "StrandiOSShared",
        ROOT / "StrandiOSWidgets",
        ROOT / "NOOPWatch",
        ROOT / "NOOPWatchComplications",
        ROOT / "Packages/StrandDesign/Sources",
    ]
    n = 0
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.suffix not in {".kt", ".swift"}:
                continue
            if process_file(path):
                n += 1
                print("updated", path.relative_to(ROOT))

    for xc in [
        ROOT / "Strand/Resources/Localizable.xcstrings",
        ROOT / "NOOPWatch/Localizable.xcstrings",
        ROOT / "NOOPWatchComplications/Localizable.xcstrings",
    ]:
        if xc.exists() and process_xcstrings(xc):
            n += 1
            print("updated", xc.relative_to(ROOT))

    print(f"done, {n} files touched")


if __name__ == "__main__":
    main()
