## Per-user access

Every YunoHost user automatically gets its own MTProto secret. Users retrieve it
themselves on the app's page, which is behind the YunoHost SSO: a user only ever
sees its own key, plus its own traffic statistics.

Secrets are kept in sync automatically: creating a YunoHost user generates a new
secret, deleting a user revokes it. Restrict who gets access with the app's
permission (`Users` group) in the webadmin.

## Self-service key reset

The app's page (in English, French or Russian, following the browser language)
also carries step-by-step Telegram setup instructions and a **Reset key**
button, so a user whose key leaked can rotate it without
asking an admin. A user can only ever reset its own key: the request is
authenticated by the SSO header and additionally signed with a per-user CSRF
token derived from the current secret.

`index.php` runs as the `mtg-multi` system user and therefore may rewrite the
secret files atomically, but not signal the service directly. Instead it touches
`/var/www/mtg-multi/conf/.reload`, which the `mtg-multi-reload.path` systemd unit
watches; that unit triggers the oneshot `mtg-multi-reload.service`, which reloads
the proxy via `SIGHUP` (`systemctl reload-or-restart mtg-multi`). Unchanged users
keep their live sessions while sessions using the old or revoked secret are
closed immediately. No sudo rule and no `exec()` from PHP is involved.

```bash
systemctl status mtg-multi-reload.path
journalctl -u mtg-multi-reload.service
```

## WEB proxy mode (optional)

When enabled at installation time, `mtg-multi` also listens for plain HTTP on
loopback (`127.0.0.1:__PORT_WEB__`) behind Nginx TLS termination on the chosen
domain (port 443). Users see an additional `tg://webproxy` connection link on
their personal page for Telegram Desktop when direct MTProto ports are blocked.

Non-client requests to the WEB domain receive an unversioned Nginx-style `404`
response by default (or static files if `decoy-dir` is configured in
`/var/www/mtg-multi/conf/mtg.toml`). The embedded bridge runtime is adapted from
telemt under the TELEMT LICENSE 3.3 (`/var/www/mtg-multi/web/LICENSE.telemt`).

## Configuration

The configuration file is at `/var/www/mtg-multi/conf/mtg.toml` and the
`username -> secret` mapping at `/var/www/mtg-multi/conf/secrets.toml`. Both are
only readable by the app's system user and are never served over HTTP.

Key settings:

- `bind-to` — The port the proxy listens on.
- `api-bind-to` — The stats API endpoint (per-user connection counts, traffic and active client IPs).
- `[network] dns` — The DNS resolver used for IP resolution.
- `[throttle]` — Automatic per-user connection limits to protect the server from overload.
- `[stats.prometheus]` — Enable/disable the Prometheus metrics endpoint.
- `[web]` — Optional loopback HTTP listener and domain for `tg://webproxy` HTTPS mode.
- `[secrets]` — Generated from `secrets.toml` (must remain the last section), do not edit by hand.

Reload secrets without dropping unchanged sessions, or restart after changing other settings:
```bash
sudo systemctl reload mtg-multi
sudo systemctl restart mtg-multi
```

## Multi-user support

mtg-multi supports multiple secrets per instance. The package writes one entry
per YunoHost user:

```toml
[secrets]
"alice" = "ee367a189aee18fa31c190054efd4a8e..."
"bob" = "ee0123456789abcdef0123456789abcd..."
```

Each key is a user name, used for per-user stats tracking.

## Stats API

mtg-multi provides a lightweight HTTP endpoint that shows live per-user traffic:

```bash
curl http://127.0.0.1:9090/stats
```

Response example:
```json
{
  "started_at": "2026-03-29T10:30:00Z",
  "uptime_seconds": 3600,
  "total_connections": 15,
  "users": {
    "alice": {
      "connections": 8,
      "bytes_in": 1048576,
      "bytes_out": 2097152,
      "last_seen": "2026-03-29T11:25:30Z",
      "active_ips": ["198.51.100.4", "2001:db8::1"]
    }
  }
}
