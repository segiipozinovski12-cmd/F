# Deploy your relay

1. Point a domain to your server. Install Docker Engine and Compose through the operating system's supported installation route.
2. Clone this repository and branch. Copy `.env.example` to `.env` and set `VO1D_DOMAIN=chat.your-domain.tld`.
3. Allow incoming TCP 80/443. Keep 8080 private; Compose does not publish it.
4. Run `docker compose up -d --build`. Caddy obtains and renews HTTPS certificates.
5. Open `https://chat.your-domain.tld/health`; expected JSON: `{"status":"ok","protocol":1}`.
6. Set the same HTTPS URL on two iPhones/simulators, create identities and exchange QR invitations.
7. Send text, a photo and a voice note both ways. Check queued/sent/delivered/read, force-close one client and reopen it, then test blocking and deletion.

The relay runs as UID 10001 with a read-only container filesystem; only `/data` and `/tmp` are writable. SQLite WAL supports the two workers through database locking. Message content remains encrypted; disk encryption on the host is still recommended for metadata. Docker volumes survive container recreation. Do not run `docker compose down -v` unless intending to erase all server data.

Operations: `docker compose ps`, `docker compose logs --tail=80 relay`, `docker compose logs --tail=80 caddy`. Do not enable access logging with authorization headers or request bodies. Configure external health monitoring if required; no monitoring account is included.

This repository does not provision a paid server, register a domain, buy an Apple membership or publish to the App Store. For a development smoke test on a Mac use the local Python relay described in README; the standard-library development server is not the production entrypoint.

## Release on your iPhone

Open `ios/VO1DMessenger.xcodeproj`, select the application target, configure your Team and bundle identifier. Select a connected iPhone, approve device developer mode if prompted, and Run. For distribution use a Release archive signed by your team. Release API validation rejects HTTP.

The checked-in Info.plist marks use of non-exempt encryption for accurate review rather than assuming export exemption. Complete the appropriate export-compliance process for your distribution. Verify privacy labels against actual relay metadata retention. Add your legal terms and privacy policy before publishing a public service.
