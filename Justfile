remote_dir := "/home/bml/searxng"
host := "sxm"

# Deploy everything: proxy fleet first (creates sxng-fleet network), then SearXNG
deploy: deploy-proxy deploy-searxng

# Deploy proxy fleet to server (delegates to searx-google project)
deploy-proxy:
    just -f ../searx-google/Justfile deploy

# Deploy SearXNG config and restart instances
# If searx-google patches exist on server, merges them via -f
deploy-searxng: generate-blocklist
    rsync -avz --delete --exclude='settings/' config/ {{host}}:{{remote_dir}}/
    ssh {{host}} 'cd {{remote_dir}} && sh generate-settings.sh'
    ssh {{host}} 'cd {{remote_dir}} && docker compose down --remove-orphans'
    ssh {{host}} 'cd {{remote_dir}} && \
      if [ -f searx-google/compose.searxng-patches.yml ]; then \
        docker compose -f docker-compose.yml -f searx-google/compose.searxng-patches.yml up -d; \
      else \
        docker compose up -d; \
      fi'

# Generate the hostnames-remove.yml blocklist from .list files
generate-blocklist:
    cat blocklists/*.list \
      | sed 's/#.*//; /^[[:space:]]*$/d' \
      | sort -u \
      | sed "s/.*/- '&'/" \
      > config/searxng/hostnames-remove.yml

# Pull server config back to local (excludes generated settings)
pull:
    rsync -avz --exclude='settings/' {{host}}:{{remote_dir}}/ config/

# Show container logs (pass args like --tail 50, or a service name)
logs *args:
    ssh {{host}} 'cd {{remote_dir}} && docker compose logs {{args}}'

# Follow container logs
logs-follow *args:
    ssh {{host}} 'cd {{remote_dir}} && docker compose logs -f {{args}}'

# Show proxy fleet logs
proxy-logs *args:
    ssh {{host}} 'cd {{remote_dir}}/searx-google && docker compose logs {{args}}'

# Follow proxy fleet logs
proxy-logs-follow *args:
    ssh {{host}} 'cd {{remote_dir}}/searx-google && docker compose logs -f {{args}}'

# Show all container status (SearXNG + proxy fleet)
status:
    ssh {{host}} 'docker ps --filter name=sxng --format "table {{{{.Names}}\t{{{{.Status}}\t{{{{.Ports}}"'

# Show restart-controller logs (pass args like --tail 50)
controller *args:
    ssh {{host}} 'docker logs {{args}} sxng-controller'

# Follow restart-controller logs
controller-follow:
    ssh {{host}} 'docker logs -f sxng-controller'

# Show per-instance search counts since last restart
counts:
    ssh {{host}} 'for i in $(seq 1 10); do \
      name=$(printf "sxng-%02d" "$i"); \
      started=$(docker inspect --format "{{{{.State.StartedAt}}" "$name" 2>/dev/null) || continue; \
      count=$(docker logs --since "$started" "$name" 2>&1 | grep -c "\"GET /search" || true); \
      printf "%s: %d searches (started: %s)\n" "$name" "$count" "$(echo "$started" | cut -dT -f2 | cut -d. -f1)"; \
    done'

# Restart all SearXNG instances (forces fresh TLS fingerprints)
restart-all:
    ssh {{host}} 'for i in $(seq 1 10); do \
      docker restart -t 5 "$(printf "sxng-%02d" "$i")" & \
    done; wait'

# Pull latest SearXNG image and redeploy
upgrade:
    ssh {{host}} 'docker pull docker.io/searxng/searxng:latest'
    ssh {{host}} 'cd {{remote_dir}} && docker compose up -d'

# Fix ownership on server config dir (if container wrote as different uid)
fix-perms:
    ssh {{host}} 'docker run --rm -v {{remote_dir}}:/data alpine chown -R $(id -u):$(id -g) /data'

# Run end-to-end test of the SearXNG fleet (runs locally, not on server)
e2e:
    bash e2e-test.sh

# SSH into server in the searxng directory
ssh:
    ssh -t {{host}} 'cd {{remote_dir}} && exec $SHELL -l'
