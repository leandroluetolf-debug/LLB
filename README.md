<p align="center">
  <img src="docs/assets/logo-v3.png" alt="LLB" width="72">
</p>

<h1 align="center">LLB</h1>

<p align="center"><b>Your strap. Your data. Your machine. Offline, on-device, no cloud.</b></p>

<p align="center"><sub>A private fork of <a href="https://github.com/NoopApp/noop">NOOP</a> — branded as <b>LLB</b>, with its own app identity so it installs alongside the original.</sub></p>

<p align="center">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Android%20%C2%B7%20iOS-E8B84B?style=flat-square">
  <img alt="Local first" src="https://img.shields.io/badge/local-first-E8B84B?style=flat-square">
  <img alt="Account free" src="https://img.shields.io/badge/account-free-C8902F?style=flat-square">
  <img alt="WHOOP 4 and 5" src="https://img.shields.io/badge/works%20with-WHOOP%204.0%20%26%205.0-6B737B?style=flat-square">
  <a href="LICENSE"><img alt="License: PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-6B737B?style=flat-square"></a>
</p>

<p align="center">
  <a href="https://github.com/leandroluetolf-debug/LLB/releases">⬇&nbsp;Releases</a> ·
  <a href="#features">Features</a> ·
  <a href="#quickstart">Quickstart</a> ·
  <a href="docs/PROTOCOL.md">Protocol</a> ·
  <a href="#disclaimer">Disclaimer</a>
</p>

---

## What is LLB?

**LLB** is a standalone, fully **offline** companion app for WHOOP straps (4.0 and 5.0). It pairs over Bluetooth, stores everything on your device in SQLite, imports WHOOP / Apple Health history, and computes recovery, strain, HRV, and sleep **locally** — no WHOOP account, no cloud.

It is based on the open [NOOP](https://github.com/NoopApp/noop) project, with these LLB-specific changes:

| | |
|---|---|
| **App name** | **LLB** everywhere in the UI |
| **App icon** | Simple **LLB** wordmark on a dark background |
| **Android ID** | `com.llb.app` (installs **next to** official NOOP) |
| **Apple bundle ID** | `com.llb.app` (own App Group: `group.com.llb.app`) |
| **Donations** | Removed from the app UI |

LLB and NOOP can both be installed on the same phone. Each has its **own database** — pairing and history do not transfer between them.

> **Not affiliated with WHOOP.** LLB is an independent, unofficial interoperability project. It is not affiliated with, endorsed by, or connected to WHOOP, Inc. "WHOOP" is used only to identify the hardware. **LLB is not a medical device**; every derived metric is an approximation. See [`DISCLAIMER.md`](DISCLAIMER.md).

---

## Download

### Android (one tap)

Every push to `main` builds an APK and publishes it here:

**https://github.com/leandroluetolf-debug/LLB/releases/download/android-latest/LLB.apk**

Or open the [Releases](https://github.com/leandroluetolf-debug/LLB/releases/tag/android-latest) page and tap **LLB.apk**.

| Platform | Build | Notes |
|---|---|---|
| **Android** | [**LLB.apk**](https://github.com/leandroluetolf-debug/LLB/releases/download/android-latest/LLB.apk) (`com.llb.app`) | Android 8+ (`minSdk 26`). Sideload — enable “install unknown apps”. Play Protect may warn; use **Install anyway**. |
| **iOS** | Build in Xcode or sideload an `.ipa` | Bundle id `com.llb.app`. Free Apple ID signing expires every 7 days unless you use a paid developer account. See [`docs/IOS.md`](docs/IOS.md). |
| **macOS** | Build in Xcode | Product name **LLB**, bundle id `com.llb.app`. Not notarized — see [`docs/BUILD.md`](docs/BUILD.md). |

> **Private repo?** The download link only works for people who can access the repo (logged-in collaborators). For a public link anyone can open, set the repository to **Public** (Settings → Danger Zone → Change visibility).

Or build from source (below). Everything runs **offline**. The only optional network use is the **AI Coach**, and only with your own API key.

---

## Contents

- [Features](#features)
- [Platform status](#platform-status)
- [Architecture](#architecture)
- [Quickstart](#quickstart)
- [How your data flows](#how-your-data-flows)
- [Privacy](#privacy)
- [Attribution](#attribution)
- [Disclaimer](#disclaimer)
- [License](#license)
- [Docs](#docs)

---

## Features

The same feature set ships on macOS, Android, and iOS via shared cross-platform code.

| Screen | What it does |
|---|---|
| **Today** | Home dashboard: recovery, strain, sleep, HRV, RHR, SpO₂, respiratory, steps, live battery & HR, recent workouts. |
| **Readiness** | On-device “should you push today?” synthesis from your own history (HRV, RHR, load balance, etc.). Not medical advice. |
| **Live** | Real-time strap view — heart rate and frame stream (~1 Hz). |
| **Breathe** | HRV haptic breathing biofeedback with pre/post HRV outcome. |
| **Intervals** | Silent haptic HIIT timer on the strap (or on-screen fallback). |
| **Explore** | Interrogate any single metric over time. |
| **Compare** | Plot two metrics on a shared timeline. |
| **Insights** | Behavioral / correlational insights from your own series. |
| **Sleep** | Sessions, hypnogram, stages, efficiency, resting HR, HRV. |
| **Trends** | Long-range trends and an on-device shareable PDF report. |
| **Workouts** | Detected and manual sessions with HR zones and Effort. |
| **Health** | Biometric overview (HR, HRV, SpO₂, skin temp, respiratory rate, …). |
| **Stress** | Day-level stress / autonomic load. |
| **Data Sources** | Import WHOOP CSV, Apple Health, nutrition CSV; live-strap status. |
| **Coach** | Optional AI Coach (your own API key / local model only). |
| **Settings** | Profile, units, step calibration, What’s new, experimental 5/MG probes. |

Also: menu-bar extra (macOS), onboarding wizard, automations (double-tap, wear presence, haptic coaching, smart alarm), and widgets where the platform allows.

### Strap support

| Strap | Status |
|---|---|
| **WHOOP 4.0** | ✅ Tested path — live HR, recovery, strain, sleep, history offload. |
| **WHOOP 5.0 / MG** | 🧪 Live HR works. Deeper scores still being mapped. Pairing needs the strap free from the official WHOOP app bond — see upstream docs in [`docs/IOS.md`](docs/IOS.md) / onboarding in-app. |

A WHOOP strap holds an encrypted Bluetooth **bond with only one device at a time**. Close the official WHOOP app (or turn its Bluetooth off), put the strap in pairing mode, then connect in LLB.

---

## Platform status

| Platform | Status |
|---|---|
| **macOS** | Full app (`Strand/`, SwiftUI, macOS 13+). Product name **LLB**, bundle id `com.llb.app`. |
| **Android** | Full app (`android/`, Jetpack Compose, Android 8+). Application id `com.llb.app`. |
| **iOS** | App target `NOOPiOS` in Xcode (product name **LLB**), bundle id `com.llb.app`. Sideload or build from source. |

---

## Architecture

```
Packages/
├── WhoopProtocol/     BLE framing, CRC, command/event/packet decode
├── WhoopStore/        SQLite (GRDB) persistence
├── StrandAnalytics/   Recovery / strain / HRV / sleep math
├── StrandImport/      WHOOP CSV + Apple Health importers
└── StrandDesign/      SwiftUI design system

Strand/                macOS app
StrandiOS/             iOS app shell
android/               Android app (Kotlin port of the same behaviour)
```

---

## Quickstart

### Android

```bash
cd android
./gradlew assembleFullRelease   # or assembleFullDebug
```

APK output under `android/app/build/outputs/apk/`. Application id: **`com.llb.app`**.

Requires **JDK 17** and the Android SDK (Android Studio is the easiest path).

### macOS / iOS

**Requirements:** macOS 13+, Xcode, Bluetooth for live pairing.

```bash
git clone https://github.com/leandroluetolf-debug/LLB.git
cd LLB

brew install xcodegen   # if needed
xcodegen generate
open Strand.xcodeproj
```

- **macOS:** scheme for the Mac app → Run. Built app is named **LLB** (`com.llb.app`).
- **iOS:** scheme **NOOPiOS** → your Team + device → Run. Bundle id **`com.llb.app`**.

Packages alone:

```bash
cd Packages/WhoopProtocol && swift build && swift test
```

---

## How your data flows

```
WHOOP strap ──BLE──▶ app BLE / Collect ──▶ WhoopProtocol (decode)
                                                │
WHOOP CSV   ─┐                                  ▼
Apple Health ├─▶ StrandImport ──────────▶ WhoopStore (local SQLite)
Nutrition CSV┘                                  │
                                                ▼
                                  StrandAnalytics (on-device scores)
                                                │
                                                ▼
                                    SwiftUI / Compose UI
```

Every arrow stays on your machine.

---

## Privacy

**Offline by design.** LLB has no server, no telemetry, and no account. Strap data, imports, and computed metrics live in a local SQLite database on your device and never leave it (except the optional AI Coach, only if you enable it with your own key).

---

## Attribution

LLB is based on **[NOOP](https://github.com/NoopApp/noop)** and stands on community protocol work:

- **`johnmiddleton12/my-whoop`** — WHOOP 4.0 BLE protocol
- **`b-nnett/goose`** — WHOOP 5.0 / MG BLE protocol documentation
- **`groue/GRDB.swift`** — SQLite persistence
- **`weichsel/ZIPFoundation`** — export unzipping

No WHOOP proprietary code, firmware, logos, or assets. Full detail in [`ATTRIBUTION.md`](ATTRIBUTION.md).

Upstream community: [r/NOOPApp](https://www.reddit.com/r/NOOPApp/), [noop.fans](https://noop.fans), [NoopApp/noop](https://github.com/NoopApp/noop).

---

## Disclaimer

LLB is an independent, unofficial, non-commercial interoperability project. It is **not affiliated with, endorsed by, or connected to WHOOP, Inc.**

**LLB is not a medical device.** Heart rate, HRV, recovery, strain, sleep stages, SpO₂, respiratory rate, and skin temperature are **approximations**. They are not clinically validated and are not medical advice.

Provided **as-is**, with **no warranty**, for **personal and educational use**. Full notice: [`DISCLAIMER.md`](DISCLAIMER.md).

---

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE): **free for personal and other non-commercial use**. Commercial use is not granted by this license.

Keep the [`LICENSE`](LICENSE) and copyright notices intact when forking or mirroring. Upstream copyright: NoopApp / contributors. Protocol facts (frame layouts, command numbers) are uncopyrightable; dependencies keep their own licenses (see [`NOTICE`](NOTICE)).

---

## Docs

- [`CHANGELOG.md`](CHANGELOG.md) — release history (also in-app under **What’s new**)
- [`DISCLAIMER.md`](DISCLAIMER.md) — trademark, interoperability, medical/legal notice
- [`ATTRIBUTION.md`](ATTRIBUTION.md) — credits and licensing notes
- [`docs/BUILD.md`](docs/BUILD.md) — build details
- [`docs/IOS.md`](docs/IOS.md) — iOS install & build
- [`docs/ANDROID.md`](docs/ANDROID.md) — Android port guide
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — BLE protocol notes
- [`project.yml`](project.yml) — XcodeGen project definition
