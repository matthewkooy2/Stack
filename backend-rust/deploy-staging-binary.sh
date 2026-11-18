#!/usr/bin/env bash
# Update staging's Rust API using the assets and worker from its current release.
set -euo pipefail
binary=${1:?path to the Linux release binary}
expected=${2:?expected current staging release name}
[[ -x $binary && $expected =~ ^[a-zA-Z0-9_-]+$ ]]
vm=/usr/local/sbin/stack-vm-ssh
[[ $("$vm" staging hostname </dev/null) == stack-staging ]]
digest=$(sha256sum "$binary" | cut -d' ' -f1)
upload=$("$vm" staging 'mktemp /var/tmp/stack-api.XXXXXXXX' </dev/null)
[[ $upload =~ ^/var/tmp/stack-api\.[[:alnum:]]{8}$ ]]
trap '"$vm" staging "rm -f -- $upload" </dev/null' EXIT
"$vm" staging "cat > $upload" < "$binary"
"$vm" staging "sudo bash -s -- $expected $digest $upload" <<'REMOTE'
set -euo pipefail
[[ $(hostname) == stack-staging ]]
exec 9>/run/lock/stack-staging-api-release.lock
flock -x 9
root=/opt/stack-rust
previous=$root/releases/$1
[[ $(readlink -f "$root/current") == "$previous" ]]
stamp=$(printf '%s\n%s\n' "$1" "$2" | sha256sum | cut -c1-16)
release=$root/releases/staging-combined-$stamp
if [[ ! -d $release ]]; then
    draft=$(mktemp -d "$root/releases/.build.XXXXXXXX")
    trap 'rm -rf -- "$draft"' EXIT
    cp -a --reflink=auto "$previous/." "$draft/"
    install -m 0755 "$3" "$draft/stack-backend"
    printf '%s  %s\n' "$2" "$draft/stack-backend" | sha256sum -c - --status
    mv -T "$draft" "$release"
    trap - EXIT
fi
printf '%s  %s\n' "$2" "$release/stack-backend" | sha256sum -c - --status
diff -qr --exclude=stack-backend --exclude=__pycache__ "$previous" "$release" >/dev/null
activate() {
    ln -sfn "$1" "$root/.next-staging-api"
    mv -Tf "$root/.next-staging-api" "$root/current"
    systemctl restart stack-rust.service
}
[[ $(readlink -f "$root/current") == "$previous" ]]
if activate "$release"; then
    for _ in {1..40}; do
        pid=$(systemctl show stack-rust.service -p MainPID --value)
        if [[ $(readlink -f "/proc/$pid/exe") == "$release/stack-backend" ]] &&
           [[ $(curl --max-time 2 -so /dev/null -w '%{http_code}' -d '{}' http://127.0.0.1:8180/function/agent_admission) == 401 ]]; then
            printf 'Active staging release %s\n' "${release##*/}"
            exit 0
        fi
        sleep .5
    done
fi
if [[ $(readlink -f "$root/current") == "$release" ]]; then activate "$previous"; fi
exit 1
REMOTE
