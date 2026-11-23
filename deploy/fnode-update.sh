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

find_checksum_file() {
    local preflight command pin=""
    local pattern='^\{ path=(/usr/bin/sha256sum|/bin/sha256sum) ; argv\[\]=(/usr/bin/sha256sum|/bin/sha256sum) (--check|-c) (/[a-zA-Z0-9._/-]+) ; ignore_errors=no ; [^{}]*\}$'
    preflight="$(systemctl show --property=ExecStartPre --value "$service")" || return 1
    while IFS= read -r command; do
        [[ "$command" == *sha256sum* ]] || continue
        if [[ -n "$pin" || ! "$command" =~ $pattern ]]; then
            fail 'Unsupported or multiple SHA-256 checks in ExecStartPre.'
        fi
        [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] ||
            fail 'Unexpected SHA-256 command in ExecStartPre.'
        pin="${BASH_REMATCH[4]}"
    done <<< "$preflight"
    printf '%s' "$pin"
}

restore_files() {
    cp -p -- "$backup" "$work/rollback" || return 1
    if [[ -n "$checksum_file" ]]; then
        cp -p -- "$backup_dir/fnode.sha256" "$checksum_stage" || return 1
        systemctl stop "$service" || return 1
        mv -fT -- "$checksum_stage" "$checksum_file" || return 1
    fi
    mv -fT -- "$work/rollback" "$binary"
}

cleanup() {
    local status=$? previous
    trap - EXIT
    trap '' HUP INT TERM
    if (( rollback_needed )); then
        printf 'Update failed. Restoring fnode %s from %s\n' "$installed_version" "$backup" >&2
        previous="$(invocation_id)" || previous=""
        if restore_files &&
            systemctl restart --no-block "$service" &&
            wait_for_startup "$installed_version" "$previous"; then
            printf 'Rollback succeeded. fnode %s is running.\n' "$installed_version" >&2
            status=1
        else
            printf 'Rollback could not be confirmed. Backup: %s\n' "$backup" >&2
            status=2
        fi
    fi
    if [[ -n "$checksum_stage" ]]; then
        rm -f -- "$checksum_stage"
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

for tool in awk chmod chown cmp cp curl date flock journalctl jq mktemp mv realpath sha256sum sort systemctl; do
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

checksum_file="$(find_checksum_file)"
if [[ -n "$checksum_file" ]]; then
    [[ -f "$checksum_file" && ! -L "$checksum_file" &&
        "$checksum_file" == "$(realpath -- "$checksum_file")" ]] ||
        fail 'Expected a regular checksum file at the absolute ExecStartPre path.'
    pinned_checksum="$(< "$checksum_file")"
    pinned_line='^[[:xdigit:]]{64} [ *]/opt/fnode/fnode$'
    [[ "$pinned_checksum" =~ $pinned_line ]] ||
        fail 'Expected exactly one SHA-256 entry for /opt/fnode/fnode.'
    sha256sum --check --strict --status "$checksum_file" ||
        fail 'The installed fnode does not match the pinned SHA-256.'
fi

work="$(mktemp -d /opt/fnode/.fnode-update.XXXXXXXX)"
checksum_stage=""
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

if [[ -n "$checksum_file" ]]; then
    [[ "$(find_checksum_file)" == "$checksum_file" &&
        "$(< "$checksum_file")" == "$pinned_checksum" ]] ||
        fail 'The ExecStartPre checksum changed while the release was downloading.'
    printf '%s  %s\n' "${pinned_checksum%% *}" "$backup" | sha256sum --check --status ||
        fail 'The backup does not match the pinned SHA-256.'
    cp -p -- "$checksum_file" "$backup_dir/fnode.sha256"
    cmp -s -- "$checksum_file" "$backup_dir/fnode.sha256" ||
        fail "Could not verify the checksum backup in $backup_dir."
    checksum_stage="$(mktemp "${checksum_file%/*}/.fnode-checksum.XXXXXXXX")"
    printf '%s  %s\n' "${digest#sha256:}" "$binary" > "$checksum_stage"
    chown --reference="$checksum_file" -- "$checksum_stage"
    chmod --reference="$checksum_file" -- "$checksum_stage"
    printf 'Checksum backup: %s/fnode.sha256 (for %s)\n' "$backup_dir" "$checksum_file"
fi

rollback_needed=1
if [[ -n "$checksum_file" ]]; then
    systemctl stop "$service"
    mv -fT -- "$checksum_stage" "$checksum_file"
fi
mv -fT -- "$work/fnode" "$binary"
systemctl restart --no-block "$service"
wait_for_startup "$target_version" "$original_id"
rollback_needed=0
printf 'Updated fnode from %s to %s.\n' "$installed_version" "$target_version"
