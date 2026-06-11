# Cloudflare API Token Permissions

This token is for the CrowdSec Cloudflare Workers bouncer.

Create a **User API Token**:

```text
Cloudflare Dashboard
  -> My Profile
  -> API Tokens
  -> Create Token
  -> Custom token
```

Do not use:

- Global API Key
- Account API Token
- A token scoped to every zone you own

## Required Permissions

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

## Resource Scope

Limit the token to:

- Account: the account that owns `example.com`
- Zone: `example.com`

## Where To Paste It

Either put it in `debian/home-cinema.env`:

```bash
CLOUDFLARE_API_TOKEN='paste-token-here'
START_CLOUDFLARE_BOUNCER='0'
```

Or run:

```bash
sudo CLOUDFLARE_API_TOKEN='paste-token-here' ./setup-home-cinema.sh
```

Keep `START_CLOUDFLARE_BOUNCER=0` until you review:

```bash
sudo nano /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
```

Make sure the generated bouncer config only targets:

```text
example.com
emby.example.com/*
stream.example.com/*
```

Then start it:

```bash
sudo systemctl enable --now crowdsec-cloudflare-worker-bouncer
```

