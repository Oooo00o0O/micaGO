# micaGO Mac Companion

A native **macOS SwiftUI controller** for the micaGO Go relay. It launches and
monitors the local `micago` server binary, talks to its local control API, and
puts a status item in the menu bar. It is **not** a chat client and **not** a
web dashboard.

Design spec and manual test steps:
[`../docs/spec-v0.10.0-mac-companion.md`](../docs/spec-v0.10.0-mac-companion.md).

## Open in Xcode

```bash
open MicaGoCompanion.xcodeproj
```

Select the **MicaGoCompanion** scheme and **My Mac**, set Signing to
**Sign to Run Locally** (local dev), and Run. Deployment target: macOS 13.
Dependencies (via Swift Package Manager): **Sparkle** (in-app updates).

Command-line build (unsigned):

```bash
xcodebuild -project MicaGoCompanion.xcodeproj -scheme MicaGoCompanion \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Server binary it controls

The companion launches a prebuilt server binary (default `~/.micago/bin/micago`):

```bash
cd ../micago-server
scripts/update-backend.sh
```

The script builds the backend with version/commit/build-time stamps, installs
it to `~/.micago/bin/micago`, and sets the Companion's backend-path override so
local development runs the newly built binary instead of an older bundled copy.
The path stays editable in-app and persisted. The first server run creates
`~/.micago/config.yaml` with the bearer token the companion reads
(`ConfigReader` line-parses the server's flat YAML — the written format is a
shared contract, don't change it casually). **A stale backend binary is the
single most common source of "broken" Companion pages** — the dashboard warns
when the running binary's version doesn't match the newest local build.

## What it does

**Sidebar pages:** Dashboard (status, start/stop/restart, permission
diagnostics) · Connections (endpoints, pairing QR, tunnel) · Sync Control
(sync rules/settings, recent chats & messages) · Notifications · Tutorials ·
About · Settings, plus Debug (Message Inspector) and Log pinned at the bottom.

- **Server lifecycle** — start/stop/restart, health polling, combined
  process+reachability state (one source of truth drives both the dashboard
  pill and the menu-bar icon), Launch at Login.
- **Connection endpoints** — local, LAN, and an optional public URL with
  validate/save; bearer token reveal/copy and a **pairing QR** for a selected
  endpoint. Local and LAN are always active; the public URL is an extra, not a
  mode ([spec](../docs/spec-v0.11.0-connection-endpoints.md)).
- **Optional Cloudflare tunnel control** — runs an **already-configured**
  local `cloudflared tunnel run <name>` so the public URL works without a
  Terminal, with an opt-in autopilot that starts/stops the tunnel following
  server health. micaGO never logs into Cloudflare, creates tunnels/DNS, or
  bundles/downloads cloudflared.
- **Sync Control** — sync rules and settings, plus recent chats/messages read
  back from the server for verification.
- **Paired devices & active connections** — registered push devices and live
  connected clients.
- **Notifications** — provider configuration (none/webhook/FCM/…), the FCM
  project/service-account paths, and the notification **preview level**
  picker; test notification.
- **Permission diagnostics** — Full Disk Access, plus a *real* Automation
  probe (a read-only AppleScript query against Messages, only when Messages is
  already running; classified by macOS's own answer, never a false denial).
- **Debug** — Message Inspector (raw recent rows with placeholders) and a
  two-way **offline test-contact scratchpad**; captured server stdout is
  **token-redacted** before display (`BackendController.redact`).
- **Keep Awake** — in-process `IOPMAssertionCreateWithName` holding
  `PreventUserIdleSystemSleep` + `NetworkClientActive` (works on battery, no
  child `caffeinate`); the toggle mirrors the assertions actually held.
- **Menu bar** — template-rendered status icon (adapts to light/dark, dims for
  transitional states, error variant for failures) with Open Dashboard /
  Start / Stop / Keep Awake / Quit.
- **Optional IMCore helper** — install *and uninstall* for the private-API
  message actions (edit/unsend/delete); install is hidden where the platform
  rules it out (macOS 26+ blocks the private IMCore APIs).
- **Updates** — in-app update checks via Sparkle.
- **Localization** — sidebar and menu are localized (English / 简体中文 /
  繁體中文, `Localization.swift`); most dashboard body text is still English.

## Not included (by design)

No chat UI, no WebUI, no Socket.IO, no micaGO cloud bootstrap, and no
BlueBubbles compatibility. Firebase/FCM is optional and user-owned. The IMCore
helper is optional, private-API based, and only enabled when the helper and
macOS environment report support. Not sandboxed and not intended for the App
Store — it is a local companion/control app.
