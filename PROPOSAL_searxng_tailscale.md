# Proposal: SearXNG + Tailscale MagicDNS (API-only; lock down LAN later)

## Goal

- Use one stable URL everywhere via **Tailscale MagicDNS**: `http://sxm:8080`
- No public exposure (do **not** port-forward `8080` on your router)
- Bring-up is simplest first (LAN + Tailscale), then restrict to **Tailscale-only** after verification
- You’ll access SearXNG via the HTTP API (JSON)

## Architecture

Laptop (this machine) → Tailnet (Tailscale) → Home server `sxm` (Tailscale) → Docker → `searxng`

## Server status assumptions

- OS: Ubuntu 24.04.x LTS
- Docker: 29.x + Compose v2
- No existing SearXNG installation

## MagicDNS setup (tailnet + server)

1) In the Tailscale admin console:

- Go to **DNS**
- Enable **MagicDNS**

2) Ensure the server appears as `sxm`:

- Install and bring up Tailscale on the home server
- Set the device name to `sxm` (so it resolves as `sxm` via MagicDNS)

3) On the laptop (this machine), confirm you can see `sxm`:

- `tailscale status`
- If `sxm` does not resolve, use the fully-qualified MagicDNS name shown in `tailscale status` (e.g. `sxm.<your-tailnet>.ts.net`).

## Files to create

### 1) `/opt/searxng/docker-compose.yml` (Phase 1: simplest; LAN + Tailscale)

```yml
services:
  searxng:
    container_name: searxng
    image: docker.io/searxng/searxng:latest
    restart: unless-stopped
    networks: [searxng]
    ports:
      - "8080:8080" # temporary: reachable on LAN + via Tailscale (MagicDNS)
    volumes:
      - ./searxng:/etc/searxng:rw
      - searxng-data:/var/cache/searxng:rw
    environment:
      - SEARXNG_BASE_URL=http://${SEARXNG_HOST}/

networks:
  searxng:

volumes:
  searxng-data:
```

### 2) `/opt/searxng/.env`

```env
SEARXNG_HOST=sxm:8080
```

### 3) `/opt/searxng/searxng/settings.yml`

```yml
use_default_settings: true
server:
  secret_key: "<32-byte-hex-key>"
  image_proxy: true
```

## Steps

1) On the home server:

- `sudo mkdir -p /opt/searxng/searxng`
- `cd /opt/searxng`
- Create `docker-compose.yml`, `.env`, `searxng/settings.yml`
- Generate secret key: `openssl rand -hex 32`

2) Start SearXNG:

- `docker compose up -d`

3) Confirm access via API (from laptop (this machine), over MagicDNS):

- `curl -sG "http://sxm:8080/search" --data-urlencode "q=test" --data "format=json" | jq '.results[0].url'`
- If `/search` doesn’t work in your build, try:
  - `curl -sG "http://sxm:8080/" --data-urlencode "q=test" --data "format=json" | jq '.results[0].url'`

## Phase 2: lock down LAN (after the API call works)

After step (3) succeeds, restrict the published port so it is reachable from Tailscale but not from your LAN.

### Option A (simple; keeps `http://sxm:8080`): bind to the server’s Tailscale IP

Find the server’s Tailscale IPv4 address (the `100.x.y.z` shown next to `sxm` in `tailscale status`) and bind the published port to it:

```yml
ports:
  - "100.x.y.z:8080:8080"
```

### Option B (more flexible): firewall by interface

Keep `ports: ["8080:8080"]` and use a firewall rule to allow `8080` only on `tailscale0` (and block it on the LAN interface).

## Optional (later): Redis

If you later want Redis-backed features, add a `redis` service (e.g. `redis:7-alpine`) and the corresponding SearXNG config at that time. For this proposal, Redis is intentionally omitted and **limiter is disabled**.
