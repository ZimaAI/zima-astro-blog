#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

root=${DEPLOY_ROOT:-/var/www/zima-astro-blog}
release=${1:?Usage: release.sh RELEASE_ID}
[[ "$release" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,100}$ ]] || exit 2
target="$root/releases/$release"
exec 9>"$root/.deploy.lock"
flock -w 120 9
for file in index.html 404.html rss.xml sitemap-index.xml robots.txt; do
    test -s "$target/$file" || { echo "Missing $file" >&2; exit 1; }
done
test -d "$target/_astro"
test -d "$target/pagefind"
# Production releases must never contain a local development canonical URL.
grep -q 'https://aboutme.zimagent.top' "$target/index.html"
printf '%s\n' "$release" > "$target/deploy-version.txt"
chmod -R u=rwX,go=rX "$target"
mkdir -p "$root/assets"
rsync -a --chmod=D755,F644 "$target/_astro/" "$root/assets/"

previous=$(readlink "$root/current" || true)
pending="$root/.current-$$"
activated=false
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
rollback() {
    status=$?
    trap - EXIT
    rm -f "$pending"
    if [[ "$activated" == true && "$status" != 0 ]]; then
        if [[ -n "$previous" ]]; then
            ln -s "$previous" "$pending"
            mv -Tf "$pending" "$root/current"
        else
            rm -f "$root/current"
        fi
        echo "Health check failed; restored previous release." >&2
    fi
    exit "$status"
}
trap 'rollback' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ln -s "releases/$release" "$pending"
mv -Tf "$pending" "$root/current"
activated=true

url=${HEALTHCHECK_URL:-https://aboutme.zimagent.top}
for attempt in {1..5}; do
    actual=$(curl --noproxy '*' --fail --silent --show-error --max-time 10 \
        --resolve aboutme.zimagent.top:443:127.0.0.1 \
        --resolve aboutme.zimagent.top:80:127.0.0.1 \
        "$url/deploy-version.txt" || true)
    if [[ "$actual" == "$release" ]]; then
        echo "Deployed $release"
        exit 0
    fi
    echo "Health check attempt $attempt/5 failed." >&2
    sleep 2
done
exit 1
