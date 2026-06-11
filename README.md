
Cloudflare and Mikrotik Edge and Local Defence. The safest way to publish your Emby/Plex or Jellyfin server whithout the need to open ports on your router.

# Home Cinema Edge Defense

This bundle deploys a Cloudflare Tunnel named `home-cinema`, an Nginx reverse proxy on Debian 12.11, local CrowdSec detection, Cloudflare edge blocking via the CrowdSec Cloudflare Workers bouncer, and a MikroTik RouterOS offender updater.

## Topology

```text
Cloudflare edge
  -> Cloudflare Tunnel: home-cinema
  -> Debian proxy: 192.168.1.10
  -> emby.example.com   -> 192.168.1.110:8096
  -> stream.example.com -> 192.168.1.118:8096
```

The MikroTik router is `192.168.1.1` on RouterOS 7.23. It fetches:

```text
http://192.168.1.10:8088/mikrotik/offenders.rsc
```

Nginx uses:

- `127.0.0.1:18080` for Cloudflare Tunnel traffic.
- `${FEED_BIND_IP:-0.0.0.0}:8088` for the MikroTik feed endpoint.

Port `8080` is intentionally left for CrowdSec's local API.

If Docker says `bind: cannot assign requested address`, the value being used for the feed bind IP is not assigned to the Debian server. Set `FEED_BIND_IP=0.0.0.0` in `debian/home-cinema.env` or `/opt/home-cinema-edge/.env`. Keep `LAN_IP` set to the address the MikroTik should fetch.

## Debian Install

## GitHub-Safe Config

This project is safe to publish when you commit only the templates and examples. Do not commit generated files containing tokens.

Ignored local files:

- `debian/home-cinema.env`
- `routeros/home-cinema-router.generated.rsc`
- `*.token`, `*.secret`, `*.key`, `*.pem`

Use one of these local configuration forms:

```bash
cd debian
bash ./configure-home-cinema.sh
sudo ./setup-home-cinema.sh
```

Or open `config-form.html` in a browser. It runs locally/offline and generates:

- `home-cinema.env`
- `home-cinema-router.generated.rsc`

Nothing is uploaded by the form.

Before pushing to GitHub, sanity-check for accidental secrets:

```bash
grep -RInE 'eyJ|TUNNEL_TOKEN=.+|CLOUDFLARE_API_TOKEN=.+|password|secret|api[_-]?key' . --exclude-dir=.git
```

Blank example keys are fine; real token values should only live in ignored local files.

## Debian Install

Copy the `debian` directory to the Debian server. If you already generated `home-cinema.env`, just run:

```bash
cd debian
sudo ./setup-home-cinema.sh
```

For the most fool-proof fresh-server path, create a remotely managed Cloudflare Tunnel named `home-cinema` in Cloudflare Zero Trust first, add public hostnames for:

- `emby.example.com` -> `http://127.0.0.1:18080`
- `stream.example.com` -> `http://127.0.0.1:18080`

Then run the installer with the tunnel token copied from Cloudflare:

```bash
cd debian
sudo TUNNEL_TOKEN='paste-cloudflare-tunnel-token-here' ./setup-home-cinema.sh
```

Or use the included environment template:

```bash
cd debian
cp home-cinema.env.example home-cinema.env
nano home-cinema.env
sudo ./setup-home-cinema.sh
```

This avoids the interactive `cloudflared tunnel login` flow. Cloudflare documents this token service install pattern as `sudo cloudflared service install <TOKEN>`.

If you prefer the locally managed tunnel flow, run without `TUNNEL_TOKEN`; the installer will call `cloudflared tunnel login`, create/reuse tunnel `home-cinema`, and route both DNS names.

The installer handles Cloudflare apt key failures such as `NO_PUBKEY 254B391D8CACCBF8` by removing stale `cloudflared` apt source files, reinstalling Cloudflare's signing key, and falling back to Cloudflare's official latest `.deb` from GitHub if apt still refuses the repository.

If you already have the stack at `/opt/home-cinema-edge`, copy the new files over and run:

```bash
cd /opt/home-cinema-edge
sudo ./repair-home-cinema.sh
sudo systemctl restart cloudflared crowdsec
sudo systemctl restart home-cinema-offenders.service || true
```

If your server uses old Compose, `repair-home-cinema.sh` automatically uses `docker-compose`.

## Cloudflare Bouncer

After the tunnel and proxy are healthy, generate the Cloudflare Workers bouncer config:

```bash
cd debian
sudo CLOUDFLARE_API_TOKEN='paste-token-here' ./setup-home-cinema.sh
```

### Cloudflare API Token Permissions

Create a **User API Token**, not an Account API Token and not the Global API Key.

Cloudflare path:

```text
Cloudflare Dashboard
  -> My Profile
  -> API Tokens
  -> Create Token
  -> Custom token
```

Use these permissions for the CrowdSec Cloudflare Workers bouncer:

| Scope | Item | Permission |
| --- | --- | --- |
| Account | Turnstile | Edit |
| Account | Workers KV Storage | Edit |
| Account | Workers Scripts | Edit |
| Account | Account Settings | Read |
| Account | D1 | Edit |
| User | User Details | Read |
| Zone | DNS | Read |
| Zone | Workers Routes | Edit |
| Zone | Zone | Read |

Resource scope:

- Account resources: include only the Cloudflare account that owns `example.com`.
- Zone resources: include only `example.com`.

Do not scope the token to all accounts/zones unless you intentionally want the bouncer to inspect everything your Cloudflare user can access.

Review `/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml` before starting it. Scope it to:

- `example.com`
- `emby.example.com/*`
- `stream.example.com/*`

Then start:

```bash
sudo systemctl enable --now crowdsec-cloudflare-worker-bouncer
```

## MikroTik Install

Upload `routeros/home-cinema-router.rsc` to the MikroTik and run:

```routeros
/import file-name=home-cinema-router.rsc
/system script run home-cinema-update-offenders
```

## Feed Tests

On Debian:

```bash
curl -i http://192.168.1.10:8088/mikrotik/health
curl -i http://192.168.1.10:8088/mikrotik/offenders.rsc
sudo docker exec home-cinema-nginx ls -la /usr/share/nginx/feed
sudo tail -n 30 /opt/home-cinema-edge/logs/nginx/feed-access.log
sudo tail -n 30 /opt/home-cinema-edge/logs/nginx/feed-error.log
```

If `/mikrotik/health` is `200` but `/mikrotik/offenders.rsc` is `403`, check file permissions in `/opt/home-cinema-edge/feed/public`. The files should be world-readable. The feed server no longer uses Nginx `allow`/`deny` rules; access is limited by binding Docker to `${FEED_BIND_IP:-0.0.0.0}:8088`.

The installer now runs these checks automatically. If the feed breaks later:

```bash
sudo /opt/home-cinema-edge/repair-home-cinema.sh
```

## Add Blocklists

The MikroTik feed generator already includes FireHOL level 1, DShield top IPs, and abuse.ch Feodo Tracker. Add extra IPv4/CIDR feeds in:

```bash
sudo nano /opt/home-cinema-edge/feed/blocklists.json
```

Each feed entry uses:

```json
{
  "name": "example_feed",
  "url": "https://example.invalid/list.txt",
  "parser": "text",
  "enabled": true
}
```

Use `parser: "text"` for one-IP-or-CIDR-per-line style lists, and `parser: "csv"` for CSV feeds. The script ignores private, multicast, loopback, and IPv6 addresses before writing RouterOS entries.

After editing:

```bash
sudo systemctl restart home-cinema-offenders.service || sudo python3 /opt/home-cinema-edge/feed/build-mikrotik-offenders.py --output-dir /opt/home-cinema-edge/feed/public --feeds-file /opt/home-cinema-edge/feed/blocklists.json
curl -i http://192.168.1.10:8088/mikrotik/offenders.rsc
```

Then on MikroTik:

```routeros
/system script run home-cinema-update-offenders
```

Start with small, high-confidence lists. Big aggregate lists can fill low-memory MikroTik devices and cause false positives.

## Router Tests

```routeros
/system script run home-cinema-update-offenders
/ip firewall address-list print where list=home_cinema_offenders
/log print where message~"home-cinema"
```
