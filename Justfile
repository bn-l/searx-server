remote_dir := "/home/bml/searxng"
host := "sxm"

# Deploy config to server and restart the container
deploy:
    ssh {{host}} 'cd {{remote_dir}} && docker compose down && docker run --rm -v {{remote_dir}}/searxng:/data alpine chown -R $(id -u):$(id -g) /data'
    rsync -avz --delete config/ {{host}}:{{remote_dir}}/
    ssh {{host}} 'cd {{remote_dir}} && docker compose up -d'

# Pull server config back to local
pull:
    rsync -avz {{host}}:{{remote_dir}}/ config/

# Show container logs (pass args like --tail 50)
logs *args:
    ssh {{host}} 'cd {{remote_dir}} && docker compose logs {{args}}'

# Follow container logs
logs-follow *args:
    ssh {{host}} 'cd {{remote_dir}} && docker compose logs -f {{args}}'

# Show container status
status:
    ssh {{host}} 'docker ps --filter name=searxng'

# SSH into server in the searxng directory
ssh:
    ssh -t {{host}} 'cd {{remote_dir}} && exec $SHELL -l'
