# micaGO Android client (Flutter)

Android-first Flutter client for a **micaGO** relay server. Pair with your Mac
over LAN or an optional public URL, sync chats and messages, send text,
attachments, and voice messages, and (optionally) receive push notifications.

See the [root README](../README.md) for the project overview and the
[CHANGELOG](../MicaGoServer/docs/CHANGELOG.md) for the development history.

## Features

- **Pairing** — scan the Companion's QR code or paste its connection JSON;
  multiple LAN candidates with auto-select + a manual route switcher (LAN
  routes are preserved when a server report is transiently empty). The bearer
  token is stored in `flutter_secure_storage` (Android Keystore-backed) and
  never logged.
- **Chats & threads** — conversation list with watermark-derived unread dots
  and a draggable clear-badge gesture, pin/hide chats, message threads with
  reactions/tapbacks, replies with jump-to-source, edit/unsend rendering, send
  effects (tap "Sent with …" to play), stickers, location cards, URL previews,
  and inline image/video media with full-screen viewers.
- **Merged view (beta)** — a per-contact toggle that merges all of a contact's
  iMessage routes into one thread, paging every route's history.
- **Sending** — optimistic bubbles with delivery/read footers and tap-to-retry
  on failure; text + attachments over iMessage, SMS when the server allows it,
  voice messages recorded in-app (AAC/m4a). Multi-select supports batch
  forward and hide.
- **Realtime + catch-up** — WebSocket events plus cursor-based delta sync to
  fill gaps after the app was closed. On native platforms the WebSocket sends
  the token in the `Authorization` header (the `?token=` query form is used
  only on web, where handshake headers aren't available).
- **Media cache** — persistent on-disk cache (memory LRU on top) for
  images/stickers/video; confirmed media is server-authoritative.
- **Contacts matching** — opt-in, on-device name resolution (the address book
  is never uploaded); custom avatars per contact.
- **Notifications (optional)** — Firebase/FCM push using your own project; a
  thin wake signal, with message data refreshed over the socket/delta path.
  MessagingStyle notifications grouped per chat with contact name + avatar,
  cleared when the chat is read. Works without Firebase.
- **Keep-alive (optional, advanced)** — a foreground service that keeps the
  connection alive in the background. Default off; Android/OEM battery policy
  can still throttle it.
- **Settings backup/restore** — export a `.micagobak` file (settings,
  appearance, pin/hide state, custom avatars; the file includes the token —
  v1 is unencrypted, keep it private). Restorable from Settings or straight
  from the pairing screen after a reinstall.
- **Localization** — English, Simplified Chinese (简体), and Traditional
  Chinese (繁體), selectable in Settings or following the system locale.
- **Diagnostics** — Settings → Paired device debug (registration + connection
  diagnostics), a realtime-event log, hidden-items management, an offline test
  contact, a read-only update check (About), and a persisted developer mode
  (7 taps on the version row).

## Architecture

```
lib/
  main.dart
  app/        mica_go_app.dart · router.dart · theme.dart
  core/
    app_controller.dart            # app-wide state (profile, clients, urls, registration)
    l10n/     app_localizations.dart (en / zh-Hans / zh-Hant)
    network/  api_client.dart · websocket_client.dart (+ ws_channel_factory_io/_web)
              connection_candidate.dart · endpoint_utils.dart · update_check.dart
              push_service.dart · push_logic.dart · notification_display.dart
              notification_contact_cache.dart · device_identity.dart · …
    storage/  secure_store.dart · local_cache_store.dart (sqflite) · media_cache.dart
    backup/   backup_service.dart (.micagobak)
  features/
    pairing/    QR scan + paste-JSON onboarding (+ import backup)
    connection/ advanced manual setup + diagnostics
    chats/      thread, message render, attachments, media viewer, composer,
                voice recorder, send effects, emoji/Twemoji text
    contacts/   on-device contact matching + custom avatars
    home/       app shell + connection-problem banner/dialog
    settings/   appearance, notifications, keep-alive, backup, hidden items, debug
    debug/      realtime event log
```

State: `ChangeNotifier` + `provider`. Routing: `go_router` (guards force the
connection screen until a complete profile exists).

## Server compatibility

Targets the micaGO relay API: a shared **bearer token**
(`Authorization: Bearer …` for REST and native WebSocket; `?token=` remains
server-supported for web clients), the connection-endpoints payload
(`/api/server/urls`), chats/messages/delta, device registry, message actions,
the test-contact endpoints, and the optional FCM client config
(`/api/fcm/client`).

## Run

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # or: flutter run -d <android-device>
```

Min SDK is 23 (required by the voice-recording plugin).

## Notes

- `android:usesCleartextTraffic="true"` is enabled so the client can reach
  `http://` local/LAN servers; public access should use `https` via your
  tunnel.
- The bearer token is stored securely and never written to logs or
  `toString()`; the only place it leaves the device is the optional settings
  backup, which warns about it on export.
- Firebase, the keep-alive service, and the IMCore message actions are all
  optional and off by default. IMCore actions appear only when the Mac/helper
  reports them supported.
- Release builds keep ML Kit barcode classes via `proguard-rules.pro` — R8
  full mode otherwise strips them and crashes the QR scanner (debug builds
  won't show this).
