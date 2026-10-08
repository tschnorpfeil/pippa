# Updating Pi

Pippa ships one exact Pi release inside the app and installs it into Pi's own managed layout
(`~/.pi/agent/install/releases/<version>`). Moving to a new Pi release is one command plus a review.

## The bump

```sh
scripts/bump-pi.sh 1.1.0
```

The script:

1. Downloads the official release files for that version from Pi's installer API
   (`https://pi.dev/api/installer/releases/<v>`, `<v>/package.json`, `<v>/package-lock.json`). These are the same
   files `pi update` and Pi's `install.sh` use. It checks that they agree with each other and that every tarball's
   `integrity` matches npm, then writes them to `app/Packaging/pi-release/`.
2. Builds the payload into `.build/pi-payload-<v>` (what `build-app.sh` puts into `Contents/Resources/pi-payload`), and
   the old pin's payload from `git HEAD` if it is not there yet.
3. Runs the gates, all against a fake HOME under `.build/`, no real model, no network except the downloads above:
   - `runtime/pippa-web` `npm test` (Pippa's web fetcher; it locks no Pi package, the script checks that)
   - `runtime/pippa-guard/*.test.mjs` (including `bypass.test.mjs` against the real Pi)
   - `runtime/pippa-local-server/test/*.test.mjs` (including `real-pi.test.mjs`: `pi -p` with `pippa-local` starts the
     server through the extension; it uses `before_provider_request` and `session_before_compact`)
   - `scripts/pi-rpc-smoke.mjs`: the real Pi in RPC mode with exactly the app's flags (`--extension` guard and tools,
     `--no-context-files`, `--no-approve`, `--system-prompt`, `--session-dir`, `--session-id`, `--provider/--model`),
     the app's environment, a `models.json` provider with a `!command` key, a guarded `write` answered over
     `extension_ui_request`, the guard's receipt via `appendEntry`, `agent_settled`, and an abort
   - `PippaChecks` with `PIPPA_SETUP_CHECKS=1` and `PIPPA_MCP_CHECKS=1`, including installing the old payload and then
     the new one in a fake HOME (what an app update does on a user's Mac)
4. Prints Pi's CHANGELOG sections between the old and new version.

Before any of that, the script refuses a version outside the minor line `PiRPCClient.supportedVersionPrefix` accepts
(a new minor needs a deliberate review of the RPC contract first), and it updates the Pi version named in
`THIRD_PARTY_NOTICES.md`.

`--no-gates` only updates the pins and builds the payload.

Then read the printed CHANGELOG for anything touching the contracts below, look at `git diff --stat`, and commit.
Nothing is pushed. The next app build bundles the new Pi.

### What to look for in the CHANGELOG

- RPC: commands, `response` shape, events (`agent_settled`, `tool_execution_end`, `extension_ui_request`)
- Extension API: `tool_call`, `tool_result`, `appendEntry`, `registerMcpServer`, `ctx.ui`
- CLI flags Pippa passes (listed above) and the environment (`PI_TELEMETRY`, `PI_OFFLINE`, `PI_SKIP_VERSION_CHECK`)
- Managed install layout (`releases-v1`, `current-version`, launcher, `managed-install.json`, pruning)
- `models.json` (provider fields, `!command` keys), native MCP

If a change breaks a gate, fix Pippa; if it cannot be fixed cleanly, stay on the old pin.

Release flow: read upstream release notes → bump → gates → a short real-model smoke (`scripts/pi-rpc-spike.sh r7 …`,
which runs the standard path against a real local model) → fresh app build → `scripts/verify-app.sh --verify-runtime` → explicitly authorized
release. Pi is never updated on a customer's Mac by itself; it ships with a reviewed Pippa update. There is no Pi fork,
patched dependency or private import.

### Where the version lives

Only in the files the script writes: `app/Packaging/pi-release/*`. Checks read the version from the payload.
Mentions of a Pi version in comments are historical notes.

## Existing installs

When a user installs a new Pippa (Sparkle) that bundles a newer Pi, the installer runs on the next start
(`PiSetupFlow.prepare`, and `PiRPCChat.launcher` if the release is missing):

- **Pippa's own sessions** always start `releases/<pin>/…/cli.js` with Pippa's Node directly, never the launcher. The
  new release is cloned from the app into `staging/pippa-*`, checked with `--version`, then renamed into
  `releases/<pin>` (atomic). Old releases are not touched by this step.
- **The terminal `pi`** follows the new pin only if Pippa set up the managed layout itself and `current-version`
  still points at a release Pippa installed that is older than the pin. Then `current-version` is replaced atomically
  (temp file + rename, like Pi's own `activateManagedRelease`) and `~/.pi/agent/bin/pi --version` is run as in the
  terminal. If that does not report the pin, the old `current-version` is restored.
- **A Pi the user manages** is never changed: their own managed install (`pi` installer), a `pi update` to any
  version, including a newer one, or a `pi` from npm/Homebrew/Nix. Pippa does not downgrade the terminal and does not
  use the user's newer Pi for its own sessions: the guard and tools are tested against the pinned release, which runs
  side by side. Both share `~/.pi/agent` (settings, `models.json`, the user's extensions); Pippa only writes its
  `pippa-local` provider into `models.json`.
- **Node** for the terminal (`~/.local/share/pi-node/current`) follows a new bundled Node only if Pippa created
  `current`; the new version goes next to the old one and the link is switched atomically.
- **Cleanup:** Pippa removes releases it created itself, except the pin, the previous pin (open terminal sessions,
  rollback) and whatever `current-version` names. Releases it did not create stay.
- **Pi ≥ 1.1.0 `pi update`** keeps only the new and the previous release and may delete Pippa's pinned release from
  `~/.pi/agent/install/releases`. Pippa re-clones it on the next start.

`PippaChecks` (`PIPPA_SETUP_CHECKS=1`) covers these cases with fake payloads, and old → new with real payloads when
`PIPPA_PI_PAYLOAD_PREVIOUS` is set (the bump script sets it).
