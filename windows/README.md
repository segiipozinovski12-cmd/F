# VO1D Desktop for Windows

Windows desktop port of the `codex/anonymous-v2` messenger.

## Current implementation

- native WPF desktop client for Windows x64;
- production relay: `https://f-production-bdfe.up.railway.app`;
- Ed25519 identity + X25519 outer VO1D envelope;
- official `@signalapp/libsignal-client 0.70.0` packaged into the app runtime;
- Signal v2 session bootstrap, signed prekeys, PQXDH + Double Ratchet transport and persisted Signal state;
- direct messages, groups and channels;
- text, files, images, voice messages, replies, edits, reactions, forwarding and polls;
- typing/read/delivery state, scheduled send, queue/retry, saved messages and ephemeral media;
- folders, snippets/templates, bookmarks, drafts, reminders and local per-room settings;
- encrypted local vault using Windows DPAPI + AES-GCM;
- local PIN lock and password-encrypted backup/restore;
- username management, relay privacy controls, one-time invites, server session management and storage statistics;
- lookup by compact VO1D ID, username, full identity or invite token;
- single-file self-contained win-x64 build.

## Still not parity-complete with iOS

The Windows client is no longer the old transport-only beta, but several iOS-specific/private-network features are still not fully ported:

- private capability mailboxes and private invitation transport;
- embedded Tor / SOCKS routing and stream isolation;
- device-link / limited history archive transfer;
- live encrypted audio calls;
- APNs/PushKit equivalents are platform-specific and are not applicable as-is on Windows;
- OCR, photo redaction / EXIF privacy tooling and some advanced content-review tools;
- full multi-device live sync is not complete on iOS either.

Do not describe the project as independently audited or as guaranteeing anonymity.

## Build

The GitHub workflow `Windows Desktop EXE` performs:

1. install and self-test official libsignal runtime;
2. embed the Signal runtime;
3. restore and publish a self-contained single-file EXE;
4. launch smoke-test;
5. Windows UI Automation composer input test;
6. UI screenshot capture;
7. artifact upload.

Local build:

```powershell
cd .\windows\VO1D.SignalBridge
npm install --omit=dev
node bridge.js --selftest
cd ..\..

# CI also embeds Node + bridge + node_modules into Resources/SignalBridge.zip
# before publishing the desktop project.
dotnet restore .\windows\VO1D.Desktop\VO1D.Desktop.csproj
dotnet publish .\windows\VO1D.Desktop\VO1D.Desktop.csproj -c Release -r win-x64 --self-contained true
```

For the reproducible packaged build, prefer the GitHub Actions artifact because it includes the embedded Signal runtime.
