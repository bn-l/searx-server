# SearXNG on Tailscale

This repo acts as the source of truth for the searxng server on the local server.

It is a private SearXNG instance running on a home server (`sxm`), accessible only via Tailscale MagicDNS at `http://sxm:8080`.

## Architecture

```
Laptop → Tailnet (Tailscale) → Home server "sxm" → Docker → searxng
```

The Docker port is bound to the server's Tailscale IP (`100.113.145.41`), so it's unreachable from the local LAN — only Tailscale peers can connect.

## Prerequisites

- **Tailscale** installed on both laptop and server, MagicDNS enabled, server hostname set to `sxm`
- **Docker** with Compose v2 on the server
- **SSH** access to the server via `sxm` (e.g. an alias in `~/.ssh/config`)
- **just** command runner ([casey/just](https://github.com/casey/just))
- **rsync** on both machines

## Setup

1. Clone this repo
2. Copy the env example: `cp config/.env.example config/.env`
3. Deploy to the server: `just deploy`

## Usage

```sh
just deploy   # sync config to server and restart the container
just pull     # sync server config back to local
just logs          # show container logs (pass args, e.g. just logs --tail 50)
just logs-follow   # follow container logs (live tail)
just status        # show container status
just ssh      # ssh into server in the searxng directory
```

## API usage

```sh
curl -sG "http://sxm:8080/search" \
  --data-urlencode "q=test" \
  --data "format=json" | jq '.results[0].url'
```

## Search engines

In addition to the SearXNG defaults, [Marginalia Search](https://search.marginalia.nu/) is enabled as an extra engine.

## File structure

```
config/
  docker-compose.yml       # Docker Compose service definition
  .env                     # environment variables (gitignored)
  .env.example             # template for .env
  searxng/
    settings.yml           # SearXNG configuration
Justfile                   # deployment and management recipes
PROPOSAL_searxng_tailscale.md  # original setup proposal
```

All files under `config/` are synced to `/home/bml/searxng/` on the server via `just deploy`.
