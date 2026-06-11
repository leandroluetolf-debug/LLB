# Homebrew Cask (macOS) — setup

Once enabled, macOS users install + auto-update NOOP with:

```bash
brew tap noopapp/noop
brew install --cask noop
brew upgrade --cask noop   # later updates
```

The cask points at the macOS `.zip` attached to each GitHub Release; the
[`homebrew.yml`](../.github/workflows/homebrew.yml) workflow regenerates the cask (version + SHA256) on
every published release, so updates are zero-maintenance.

> **Unsigned-app note.** NOOP ships anonymously with no Apple Developer ID, so it isn't notarized.
> Homebrew can't strip the quarantine flag for an un-notarized app, so on **first launch** Gatekeeper
> blocks it — the user right-clicks NOOP in `/Applications` → **Open** → **Open** (once). The cask's
> `caveats` says this. Updates after that are just `brew upgrade`.

## Two one-time steps (maintainer only)

The workflow is committed but **inert** until these are done — it runs only when the repo variable
`HOMEBREW_TAP_ENABLED` is `true`.

### 1. Create the tap repo

Create a public repo **`NoopApp/homebrew-noop`** (the `homebrew-` prefix is required for `brew tap` to
find it). Empty is fine — the workflow creates `Casks/noop.rb` on the next release. Keep it anonymous
(NoopApp org, no real-name identity).

### 2. Add the token + enable

- Create a **fine-grained PAT** with **Contents: Read and write** scoped to **`NoopApp/homebrew-noop`
  only** (nothing else). Author identity doesn't matter — the workflow commits as `NoopApp`.
- In **`NoopApp/noop` → Settings → Secrets and variables → Actions**:
  - add secret **`HOMEBREW_TAP_TOKEN`** = that PAT,
  - add variable **`HOMEBREW_TAP_ENABLED`** = `true`.

Then either publish a release or run the **Update Homebrew Cask** workflow manually
(`workflow_dispatch`, pass a tag like `v1.94`) to seed the cask. Done.

## Anonymity checklist

- Tap repo under the anonymous **NoopApp** org.
- PAT scoped to **only** the tap repo's Contents — no broader access, no identity leak.
- Cask commits authored `NoopApp <thenoopapp@gmail.com>` (the workflow sets this explicitly).
- The cask installs the **already-anonymized** release zip (scrubbed by `Tools/anonymize-macos-app.sh`
  at build time) — no new surface.
