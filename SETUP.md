# Setup Guide

## Overview

This system runs a private SearXNG search instance on a home server (`sxm`), accessible only via Tailscale. It's split across three repos that live as siblings in the same parent directory:

```
misc-projects/
  searx-server/         # SearXNG fleet (this repo)
  searx-google/         # Google stealth proxy (optional)
  recaptcha-solver/     # reCAPTCHA v2 solver (dependency of searx-google)
```

**searx-server** is the core. It runs a fleet of 10 SearXNG instances behind a load balancer, serving search results from DuckDuckGo, Brave, Marginalia, and (optionally) Google.

**searx-google** is optional. It adds Google search support by running a fleet of 10 headless Brave browser proxies that bypass Google's bot detection. When deployed, it patches the SearXNG containers to route Google queries through the proxy.

**recaptcha-solver** is a standalone reCAPTCHA v2 visual challenge solver. It's a local dependency of searx-google (referenced via `path = "../recaptcha-solver"` in searx-google's `pyproject.toml`).

## Architecture

### Without searx-google (base)

```
Laptop --> Tailscale --> sxm --> SearXNG fleet (10 instances)
                                  |-> DuckDuckGo
                                  |-> Brave
                                  |-> Marginalia
```

### With searx-google

```
Laptop --> Tailscale --> sxm --> SearXNG fleet (10 instances)
                                  |-> DuckDuckGo, Brave, Marginalia (direct)
                                  |-> Google (via proxy fleet)
                                         |
                                  Proxy fleet (10 headless Brave instances)
                                    + Caddy load balancer
                                    + reCAPTCHA solver (auto-solves CAPTCHAs)
```

## Prerequisites

- **Tailscale** on both laptop and server, MagicDNS enabled, server hostname `sxm`
- **Docker** with Compose v2 on the server
- **SSH** access via `sxm`
- **just** command runner
- **rsync** on both machines

## Deploying

### SearXNG only (no Google)

```sh
cd searx-server
cp config/.env.example config/.env
just deploy-searxng
```

This syncs `config/` to the server, generates per-instance settings, and starts 10 SearXNG containers. Google searches will not work (Google blocks direct HTTP scraping), but DuckDuckGo, Brave, and Marginalia will.

### Full stack (with Google)

```sh
cd searx-server
just deploy
```

This runs `deploy-proxy` then `deploy-searxng`:

1. **deploy-proxy** delegates to `searx-google/Justfile`, which:
   - Rsyncs `searx-google/` to the server
   - Copies `recaptcha-solver` source into the build context (`_deps/`)
   - Builds and starts the proxy fleet (creates the `sxng-fleet` Docker network)

2. **deploy-searxng** syncs the SearXNG config and starts the fleet. It detects that `searx-google/compose.searxng-patches.yml` exists on the server and merges it via `docker compose -f`, which adds volume mounts that patch the Google engine to route through the proxy.

### Deploying searx-google independently

```sh
cd searx-google
just deploy
```

This deploys the proxy fleet on its own. The SearXNG fleet won't pick up the patches until you also run `just deploy-searxng` from `searx-server` (or `just deploy` which does both).

## How the patching works

searx-google owns three Python files in `patches/` that override SearXNG's Google engine:

- `google.py` — rewrites `request()` to route through `http://sxng-proxy:5000/search?url=...`
- `google_videos.py` — same for Google Videos
- `client.py` — whitelists the `sxng-proxy` hostname for plain HTTP

These are volume-mounted read-only into each SearXNG container. The mounts are defined in `searx-google/compose.searxng-patches.yml`, which is merged with searx-server's base `docker-compose.yml` at deploy time. If searx-google isn't deployed, the patches file doesn't exist and SearXNG runs vanilla.

## Server layout

After a full deploy, the server looks like:

```
/home/bml/searxng/
  docker-compose.yml              # SearXNG fleet (base, no patches)
  generate-settings.sh            # generates per-instance settings
  settings/                       # generated per-instance SearXNG config
  searxng/                        # shared SearXNG settings template
  restart-controller.sh           # sidecar that restarts containers after N searches
  searx-google/                   # proxy fleet
    compose.yaml                  # proxy Docker Compose
    compose.searxng-patches.yml   # patch fragment merged into SearXNG compose
    patches/                      # engine override files
    proxy/                        # FastAPI proxy service + Dockerfile
    _deps/recaptcha_solver/       # solver source (copied during deploy)
    lb/Caddyfile                  # load balancer config
```

## Common commands

```sh
# From searx-server/
just deploy              # deploy everything (proxy + searxng)
just deploy-searxng      # deploy only SearXNG config
just deploy-proxy        # deploy only the proxy fleet
just status              # show all container status
just logs --tail 50      # SearXNG logs
just proxy-logs --tail 50  # proxy fleet logs
just counts              # per-instance search counts
just restart-all         # restart all SearXNG instances
just e2e                 # run end-to-end tests

# From searx-google/
just deploy              # deploy proxy fleet independently
just logs --tail 50      # proxy logs
just status              # proxy container status
```
