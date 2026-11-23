#!/usr/bin/env bash
set -euo pipefail

readonly service=fnode.service
readonly binary=/opt/fnode/fnode
readonly repo=frkn-dev/fcore
readonly stable_version='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

invocation_id() {
    systemctl show --property=InvocationID --value "$service"
}

startup_log() {
    journalctl --boot --unit="$service" --output=cat --no-pager --quiet \
        --grep='^>>> Node [0-9]|Running metrics task' "_SYSTEMD_INVOCATION_ID=$1"
}

banner_version() {
    awk '$1 == ">>>" && $2 == "Node" && NF == 3 && !found { print $3; found = 1 }'
}

wait_for_startup() {
    local expected="$1" previous="$2"
    local deadline=$((SECONDS + 60)) current_id logs version ready_id=""
    while (( SECONDS < deadline )); do
        if systemctl is-active --quiet "$service" &&
            current_id="$(invocation_id)" &&
            [[ "$current_id" =~ ^[0-9a-f]{32}$ && "$current_id" != "$previous" ]] &&
            logs="$(startup_log "$current_id")"; then
            version="$(banner_version <<< "$logs")"
            if [[ -n "$version" && "$version" != "$expected" ]]; then
                printf 'Expected fnode %s, got %s\n' "$expected" "$version" >&2
                return 1
            fi
            if [[ "$version" == "$expected" && "$logs" == *"Running metrics task"* ]]; then
                [[ "$ready_id" != "$current_id" ]] || return 0
                ready_id="$current_id"
            else
                ready_id=""
            fi
        else
            ready_id=""
        fi
        sleep 1
    done
    printf 'Timed out waiting for fnode %s to finish startup\n' "$expected" >&2
    return 1
}

download() {
    curl --disable --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 "$@"
}

cleanup() {
    local status=$? previous
    trap - EXIT
    trap '' HUP INT TERM
    if (( rollback_needed )); then
        printf 'Update failed. Restoring fnode %s from %s\n' "$installed_version" "$backup" >&2
        previous="$(invocation_id)" || previous=""
        if cp -p -- "$backup" "$work/rollback" &&
            mv -fT -- "$work/rollback" "$binary" &&
            systemctl restart --no-block "$service" &&
            wait_for_startup "$installed_version" "$previous"; then
            printf 'Rollback succeeded. fnode %s is running.\n' "$installed_version" >&2
            status=1
        else
            printf 'Rollback could not be confirmed. Backup: %s\n' "$backup" >&2
            status=2
        fi
    fi
    rm -rf -- "$work"
    exit "$status"
}

if (( $# != 1 )) || [[ ! "$1" =~ ^v${stable_version}$ ]]; then
    fail "Usage: $0 vMAJOR.MINOR.PATCH"
fi
(( EUID == 0 )) || fail 'Run as root on the node.'

tag="$1"
target_version="${tag#v}"
case "$(uname -m)" in
    x86_64) asset=node-x86_64 ;;
    aarch64) asset=node-aarch64 ;;
    armv7l) asset=node-armv7 ;;
    *) fail 'Unsupported node architecture.' ;;
esac

for tool in awk chmod chown cmp cp curl date flock journalctl jq mktemp mv sha256sum sort systemctl; do
    command -v "$tool" >/dev/null || fail "Missing required command: $tool"
done

umask 077
exec 9>/run/lock/frkn-fnode-update.lock
flock -n 9 || fail 'An fnode update is already in progress.'
[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] ||
    fail "Expected an executable regular file at $binary."
exec_start="$(systemctl show --property=ExecStart --value "$service")"
[[ "$exec_start" == "{ path=$binary ;"* ]] || fail "$service does not start $binary."
systemctl is-active --quiet "$service" || fail "$service is not active."
original_id="$(invocation_id)"
[[ "$original_id" =~ ^[0-9a-f]{32}$ ]] || fail 'Could not identify the running fnode invocation.'
original_logs="$(startup_log "$original_id")" ||
    fail 'Could not read the running fnode startup log.'
installed_version="$(banner_version <<< "$original_logs")"
[[ "$installed_version" =~ ^${stable_version}$ ]] || fail 'Missing or unsupported installed version.'
if [[ "$installed_version" == "$target_version" ]]; then
    printf 'fnode %s is already running.\n' "$installed_version"
    exit 0
fi
version_order="$(printf '%s\n' "$installed_version" "$target_version" | sort -V)"
[[ "$version_order" == "$installed_version"$'\n'"$target_version" ]] ||
    fail "Target $tag is older than the running version v$installed_version."
[[ "$original_logs" == *"Running metrics task"* ]] ||
    fail 'The running fnode has no startup confirmation in the journal.'

work="$(mktemp -d /opt/fnode/.fnode-update.XXXXXXXX)"
rollback_needed=0
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

download --output "$work/release.json" "https://api.github.com/repos/$repo/releases/tags/$tag"
digest="$(jq -er --arg tag "$tag" --arg asset "$asset" '
    select(.tag_name == $tag and .draft == false and .prerelease == false)
    | [.assets[] | select(.name == $asset and .state == "uploaded")]
    | select(length == 1)
    | .[0].digest
    | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))
' "$work/release.json")" || fail "No SHA-256 digest for $asset in stable release $tag."

download --output "$work/fnode" "https://github.com/$repo/releases/download/$tag/$asset"
printf '%s  %s\n' "${digest#sha256:}" "$work/fnode" | sha256sum --check --status ||
    fail "SHA-256 mismatch for $tag/$asset."

if ! systemctl is-active --quiet "$service" || [[ "$(invocation_id)" != "$original_id" ]]; then
    fail 'The fnode invocation changed while the release was downloading.'
fi

backup_root=/opt/fnode/update-backups
mkdir -p -- "$backup_root"
backup_dir="$(mktemp -d "$backup_root/v$installed_version-$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")"
backup="$backup_dir/fnode"
cp -p -- "$binary" "$backup"
cmp -s -- "$binary" "$backup" || fail "Could not verify the backup at $backup."
chown --reference="$binary" -- "$work/fnode"
chmod --reference="$binary" -- "$work/fnode"
printf 'Backup: %s\n' "$backup"

rollback_needed=1
mv -fT -- "$work/fnode" "$binary"
systemctl restart --no-block "$service"
wait_for_startup "$target_version" "$original_id"
rollback_needed=0
printf 'Updated fnode from %s to %s.\n' "$installed_version" "$target_version"
