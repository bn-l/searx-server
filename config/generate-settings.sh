#!/bin/sh
set -eu

cd "$(dirname "$0")"

for i in $(seq -w 1 10); do
  dir="settings/sxng-${i}"
  mkdir -p "$dir"

  sed -e "s/secret_key:.*/secret_key: \"$(openssl rand -hex 32)\"/" \
      -e "s/image_proxy:.*/image_proxy: false/" \
      searxng/settings.yml > "$dir/settings.yml"

  cp searxng/hostnames-remove.yml "$dir/hostnames-remove.yml"
done

echo "Generated settings for 10 instances."
