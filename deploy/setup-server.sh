#!/usr/bin/env bash
# Run once as root after building, from any working directory.
set -Eeuo pipefail
umask 022
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
public_key=${1:?Usage: sudo bash deploy/setup-server.sh /absolute/path/to/deploy-key.pub}
root=/var/www/zima-astro-blog
account=aboutme-deploy
site=/etc/nginx/sites-available/zima-astro-blog
enabled=/etc/nginx/sites-enabled/zima-astro-blog
snippet=/etc/nginx/snippets/zima-astro-blog.conf
for command in nginx certbot rsync curl python3 runuser ssh-keygen flock; do
    command -v "$command" >/dev/null
done
ssh-keygen -lf "$public_key" >/dev/null
test -s "$source_dir/dist/index.html"
grep -q 'https://aboutme.zimagent.top' "$source_dir/dist/index.html"
nginx -t

# Refuse to replace an unrelated site or introduce a duplicate server_name.
for file in "$site" "$snippet"; do
    if [[ -e "$file" ]] && ! grep -q '^# Managed by zima-astro-blog\.' "$file"; then
        echo "Refusing to overwrite $file" >&2; exit 1
    fi
done
if [[ -e "$enabled" || -L "$enabled" ]]; then
    [[ -L "$enabled" && $(readlink "$enabled") == "$site" ]] || exit 1
fi
nginx -T 2>/dev/null | python3 -c '
import re, sys
filename = ""
for line in sys.stdin:
    if line.startswith("# configuration file "):
        filename = line.removeprefix("# configuration file ").rstrip(":\n")
    if re.search(r"^\s*server_name\s+.*\baboutme\.zimagent\.top\b", line):
        if filename != "/etc/nginx/sites-enabled/zima-astro-blog":
            sys.exit("Domain already configured in " + filename)
'

if ! id "$account" >/dev/null 2>&1; then
    useradd --create-home --user-group --shell /bin/bash "$account"
fi
[[ $(getent passwd "$account" | cut -d: -f6) == /home/aboutme-deploy ]]
install -d -o "$account" -g "$account" -m 700 /home/aboutme-deploy/.ssh
authorized=/home/aboutme-deploy/.ssh/authorized_keys
touch "$authorized"
key=$(awk '{print $1 " " $2}' "$public_key")
if ! grep -qF "$key" "$authorized"; then
    printf 'restrict %s\n' "$key" >> "$authorized"
fi
chown "$account:$account" "$authorized"
chmod 600 "$authorized"
install -d -o "$account" -g "$account" -m 755 "$root" "$root/releases" "$root/assets"
install -d -m 755 "$root/acme"

# Install only our files. Restore them if Nginx rejects the configuration.
backup=$(mktemp -d)
for file in "$site" "$snippet"; do
    [[ ! -f "$file" ]] || cp -p "$file" "$backup/$(basename "$file")"
done
had_enabled=false
[[ ! -L "$enabled" ]] || had_enabled=true
restore_config() {
    for file in "$site" "$snippet"; do
        if [[ -f "$backup/$(basename "$file")" ]]; then
            cp -p "$backup/$(basename "$file")" "$file"
        else
            rm -f "$file"
        fi
    done
    [[ "$had_enabled" == true ]] || rm -f "$enabled"
}
trap 'rm -rf "$backup"' EXIT
install -m 644 "$source_dir/deploy/site.conf" "$snippet"
config=nginx-http.conf
health=http://aboutme.zimagent.top
if [[ -f /etc/letsencrypt/live/aboutme.zimagent.top/fullchain.pem ]]; then
    config=nginx-https.conf
    health=https://aboutme.zimagent.top
fi
install -m 644 "$source_dir/deploy/$config" "$site"
ln -sfn "$site" "$enabled"
if ! nginx -t; then restore_config; exit 1; fi
if ! systemctl reload nginx; then restore_config; exit 1; fi

if [[ ! -L "$root/current" ]]; then
    release="initial-$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -o "$account" -g "$account" -m 755 "$root/releases/$release"
    rsync -a --chown="$account:$account" "$source_dir/dist/" "$root/releases/$release/"
    runuser -u "$account" -- env HEALTHCHECK_URL="$health" \
        bash -s -- "$release" < "$source_dir/deploy/release.sh"
fi

# Webroot validation keeps every other Nginx site and certificate untouched.
certbot certonly --webroot --webroot-path "$root/acme" \
    --domain aboutme.zimagent.top --cert-name aboutme.zimagent.top \
    --non-interactive --agree-tos --keep-until-expiring \
    --deploy-hook '/usr/sbin/nginx -t -q && /bin/systemctl reload nginx'
cp -p "$site" "$backup/before-https"
install -m 644 "$source_dir/deploy/nginx-https.conf" "$site"
if ! nginx -t; then cp -p "$backup/before-https" "$site"; exit 1; fi
if ! systemctl reload nginx; then cp -p "$backup/before-https" "$site"; exit 1; fi
# Reload sends a signal; the new workers may not be accepting connections yet.
# Keep certificate verification enabled and wait for the expected release.
expected=$(cat "$root/current/deploy-version.txt")
for attempt in {1..15}; do
    if actual=$(curl --noproxy '*' --fail --silent --show-error --max-time 5 \
        --resolve aboutme.zimagent.top:443:127.0.0.1 \
        https://aboutme.zimagent.top/deploy-version.txt) && [[ "$actual" == "$expected" ]]; then
        printf '%s\n' "$actual"
        echo 'Server ready: https://aboutme.zimagent.top'
        exit 0
    fi
    echo "Waiting for Nginx HTTPS configuration ($attempt/15)..." >&2
    sleep 1
done
echo 'HTTPS verification failed. Check Nginx logs and the certificate; the installed site was preserved.' >&2
exit 1
