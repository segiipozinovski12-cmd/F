# Railway deployment

VO1D Relay is ready to run as a Railway service.

## Service settings

1. Create a Railway project from this GitHub repository.
2. Use branch `codex/vo1d-monochrome-v2`.
3. Set **Root Directory** to `/server`.
4. Railway will detect `server/Dockerfile`.
5. Add a persistent Volume mounted at `/data`.
6. Set the Healthcheck Path to `/health`.
7. Under Networking choose **Generate Domain**.

No fixed port is required: the container listens on Railway's injected `PORT`.

## Runtime variables

Optional:

- `VO1D_DB=/data/relay.sqlite3` (already the image default)
- `WEB_CONCURRENCY=2`
- `GUNICORN_THREADS=4`

The entrypoint starts as root only long enough to make the mounted `/data`
directory writable, then runs Gunicorn as the unprivileged `relay` user.

## Connect the iOS app

Once Railway provides a public HTTPS domain, use:

`https://<your-railway-domain>`

in **Settings → RELAY**.

Check:

`https://<your-railway-domain>/health`

It should return JSON containing `"status":"ok"`.

## Important

The SQLite database must live on the Railway volume. Without the `/data`
volume, identities and queued messages can disappear after a redeploy.
