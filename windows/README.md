# VO1D Desktop for Windows

Windows desktop port of the `codex/anonymous-v2` branch.

## What this build includes

- native Windows WinForms shell, black/white VO1D UI;
- same production relay as the iOS app;
- Ed25519 identity + X25519 agreement compatible with the outer VO1D v1 envelope;
- server registration, challenge/session auth, compact 4-character VO1D ID;
- contact lookup by compact ID, username, or full identity;
- encrypted local identity (Windows DPAPI) and AES-GCM local vault;
- direct-message desktop UI and authenticated outer-envelope send/receive;
- single-file self-contained win-x64 publish.

## Important protocol boundary

The iOS branch now uses libsignal v2 (PQXDH + Double Ratchet) inside the VO1D transport. This first Windows build deliberately does **not** pretend that the inner libsignal-v2 layer has already been ported. It can validate/decrypt the outer VO1D envelope and recognizes a v2 SignalPacket, but full iOS↔Windows message interoperability requires the next step: port `SignalProtocol.swift` to the desktop libsignal bindings and persist the session/prekey state.

That boundary is intentional: silently downgrading to the old protocol would weaken the design.

## Build locally

```powershell
dotnet restore .\windows\VO1D.Desktop\VO1D.Desktop.csproj
dotnet publish .\windows\VO1D.Desktop\VO1D.Desktop.csproj -c Release -r win-x64 --self-contained true
```

The GitHub workflow builds the executable automatically.
