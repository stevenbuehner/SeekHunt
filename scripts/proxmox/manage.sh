#!/usr/bin/env bash
# Install/update from one branch snapshot. Never run npm or a development server as root.
set -Eeuo pipefail
umask 022

readonly REPOSITORY="stevenbuehner/SeekHunt"
readonly BRANCH="proxmox/main"
readonly APP_ROOT="/opt/seekhunt"
readonly CONFIG_ROOT="/etc/seekhunt"
readonly STATE_ROOT="/var/lib/seekhunt"
readonly BACKUP_ROOT="/var/backups/seekhunt"
readonly CACHE_ROOT="/var/cache/seekhunt"
mode="${1:-update}"
[[ "$mode" == "install" || "$mode" == "update" ]] || { echo "Usage: $0 [install|update]" >&2; exit 2; }
[[ "$EUID" == 0 ]] || { echo "Run this command as root inside the SeekHunt container." >&2; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "This installer requires Linux and systemd." >&2; exit 1; }
for command in curl jq tar node npm runuser flock systemctl; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ "$(node -p 'process.versions.node.split(".")[0]')" == 24 ]] || {
  echo "Node.js 24 is required. Update the container's Node.js installation first." >&2;
  exit 1;
}
exec 9>/run/lock/seekhunt.lock
flock -n 9 || { echo "Another SeekHunt installation/update is running." >&2; exit 1; }

old_release=""
if [[ -L "$APP_ROOT/current" && -f "$APP_ROOT/current/build/proxmox/version.json" ]]; then
  old_release="$(readlink -f "$APP_ROOT/current")"
fi
if [[ "$mode" == "install" && -f "$APP_ROOT/current/build/proxmox/version.json" ]]; then
  echo "SeekHunt is already installed. Run update instead." >&2
  exit 1
fi
if [[ "$mode" == "update" && ! -f "$APP_ROOT/current/build/proxmox/version.json" ]]; then
  echo "No complete SeekHunt installation found." >&2
  exit 1
fi

install -d -m 755 "$APP_ROOT/releases" "$CONFIG_ROOT" /usr/local/lib/seekhunt
install -d -m 700 "$BACKUP_ROOT"
if ! id seekhunt >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$CACHE_ROOT" --shell /usr/sbin/nologin seekhunt
fi
install -d -o seekhunt -g seekhunt -m 700 "$STATE_ROOT" "$CACHE_ROOT"
if [[ ! -f "$CONFIG_ROOT/seekhunt.env" ]]; then
  printf 'LISTEN_ADDRESS=0.0.0.0\nPORT=8787\n' >"$CONFIG_ROOT/seekhunt.env"
  chmod 644 "$CONFIG_ROOT/seekhunt.env"
fi
# This file is root-owned and also read by systemd's EnvironmentFile directive.
# shellcheck disable=SC1091
source "$CONFIG_ROOT/seekhunt.env"
[[ "${PORT:-}" =~ ^[1-9][0-9]{0,4}$ && "$PORT" -le 65535 ]] || {
  echo "Invalid PORT in $CONFIG_ROOT/seekhunt.env" >&2; exit 1;
}
[[ "${LISTEN_ADDRESS:-}" == "0.0.0.0" || "${LISTEN_ADDRESS:-}" == "127.0.0.1" ]] || {
  echo "LISTEN_ADDRESS must be 0.0.0.0 or 127.0.0.1." >&2; exit 1;
}

workspace=""
candidate=""
backup=""
backup_ready=0
switching=0
healthy=0

wait_for_service() {
  local expected_commit="$1" attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    if systemctl is-active --quiet seekhunt &&
      curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:${PORT}/_health" |
        jq -e --arg commit "$expected_commit" '.status == "ok" and .commit == $commit' >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

rollback() {
  systemctl stop seekhunt || return 1
  if ((backup_ready)); then
    # Replace the entire state tree: do not leave new SQLite/WAL files behind.
    rm -rf "$STATE_ROOT" || return 1
    tar -xzf "$backup" -C / || return 1
  fi
  ln -sfnT "$old_release" "$APP_ROOT/current.rollback" || return 1
  mv -Tf "$APP_ROOT/current.rollback" "$APP_ROOT/current" || return 1
  systemctl daemon-reload || return 1
  systemctl reset-failed seekhunt || true
  systemctl start seekhunt || return 1
  local old_commit
  old_commit="$(jq -er .commit "$old_release/build/proxmox/version.json")" || return 1
  wait_for_service "$old_commit"
}

cleanup() {
  local result="$?"
  trap - EXIT INT TERM HUP
  set +e
  if ((switching && !healthy)); then
    echo "Deployment failed. Recent service logs:" >&2
    journalctl -u seekhunt -n 30 --no-pager >&2
    if [[ -n "$old_release" && -d "$old_release" ]]; then
      if rollback; then
        echo "Restored the previous version and its saved room state." >&2
      else
        echo "Automatic rollback failed. Keep the backup: $backup" >&2
        echo "Inspect: journalctl -u seekhunt -n 100 --no-pager" >&2
      fi
    else
      systemctl disable --now seekhunt >/dev/null 2>&1
      rm -f "$APP_ROOT/current" /etc/systemd/system/seekhunt.service
      systemctl daemon-reload
    fi
  fi
  if [[ -n "$candidate" && "$(readlink -f "$APP_ROOT/current" 2>/dev/null)" != "$candidate" ]]; then
    rm -rf "$candidate"
  fi
  [[ -z "$workspace" ]] || rm -rf "$workspace"
  [[ -z "$backup" ]] || rm -f "$backup.tmp"
  rm -f "$APP_ROOT/current.next" "$APP_ROOT/current.rollback" "$APP_ROOT/previous.next"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Resolve the branch once, then download that exact commit without .git/history/other branches.
branch_path="$(jq -rn --arg branch "$BRANCH" '$branch | @uri')"
commit="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
  "https://api.github.com/repos/${REPOSITORY}/branches/${branch_path}" | jq -er .commit.sha)"
[[ "$commit" =~ ^[a-f0-9]{40}$ ]] || { echo "Invalid branch commit." >&2; exit 1; }
if [[ -n "$old_release" && -f "$old_release/build/proxmox/version.json" ]] &&
  [[ "$(jq -r .commit "$old_release/build/proxmox/version.json")" == "$commit" ]]; then
  echo "SeekHunt is already at ${BRANCH} (${commit:0:12})."
  exit 0
fi

# Keep enough space for npm, a candidate release and a consistent data backup on the 6 GB disk.
available_kb="$(df -Pk "$APP_ROOT" | awk 'END {print $4}')"
state_kb="$(du -sk "$STATE_ROOT" | awk '{print $1}')"
if ((available_kb < 1572864 + state_kb)); then
  echo "Need at least 1.5 GiB free plus the size of the room data before deployment." >&2
  exit 1
fi
workspace="$(mktemp -d /var/tmp/seekhunt.XXXXXXXX)"
candidate="$(mktemp -d "$APP_ROOT/releases/${commit:0:12}.XXXXXXXX")"
echo "Downloading ${REPOSITORY}@${BRANCH} (${commit:0:12})..."
curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 \
  "https://codeload.github.com/${REPOSITORY}/tar.gz/${commit}" -o "$workspace/source.tar.gz"
tar -xzf "$workspace/source.tar.gz" --strip-components=1 --no-same-owner -C "$candidate"
rm -f "$workspace/source.tar.gz"
[[ -f "$candidate/scripts/proxmox/build.mjs" && -f "$candidate/package-lock.json" ]] || {
  echo "The selected branch does not contain the SeekHunt Proxmox installer." >&2; exit 1;
}
chown -R seekhunt:seekhunt "$candidate"
chmod 755 "$candidate"
echo "Installing locked dependencies and building the production web app and Worker..."
(
  cd "$candidate"
  runuser -u seekhunt -- env HOME="$CACHE_ROOT" npm_config_cache="$CACHE_ROOT/npm" \
    npm ci --no-audit --no-fund
  runuser -u seekhunt -- env HOME="$CACHE_ROOT" NODE_OPTIONS=--max-old-space-size=1024 npm run build
  runuser -u seekhunt -- env SEEKHUNT_COMMIT="$commit" node scripts/proxmox/build.mjs
)
chown -R root:root "$candidate"
# The locked dependency tree provides the runtime; updates never install workerd@latest.
[[ -x "$candidate/node_modules/.bin/workerd" ]] || { echo "workerd is missing." >&2; exit 1; }
new_runtime="$(jq -er .workerd "$candidate/build/proxmox/version.json")"
old_runtime=""
if [[ -n "$old_release" ]]; then
  old_runtime="$(jq -er .workerd "$old_release/build/proxmox/version.json")"
fi
echo "Preparing workerd ${new_runtime}${old_runtime:+ (previously ${old_runtime})}."

# Builds finish while the old server still runs. Only the switch and backup interrupt games.
switching=1
if [[ -n "$old_release" ]]; then
  systemctl stop seekhunt
  old_commit="$(jq -er .commit "$old_release/build/proxmox/version.json")"
  backup="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-${old_commit}.tar.gz"
  tar -czf "$backup.tmp" -C / var/lib/seekhunt etc/seekhunt etc/systemd/system/seekhunt.service
  chmod 600 "$backup.tmp"
  mv "$backup.tmp" "$backup"
  backup_ready=1
fi
install -m 644 "$candidate/scripts/proxmox/seekhunt.service" /etc/systemd/system/seekhunt.service
ln -sfnT "$candidate" "$APP_ROOT/current.next"
mv -Tf "$APP_ROOT/current.next" "$APP_ROOT/current"
systemctl daemon-reload
systemctl reset-failed seekhunt || true
systemctl enable --now seekhunt
if ! wait_for_service "$commit"; then
  echo "SeekHunt failed its startup health check." >&2
  exit 1
fi
healthy=1
install -m 644 "$candidate/build/proxmox/version.json" "$CONFIG_ROOT/version.json"

# Promote the updater only after its release has started successfully. Rename, never overwrite
# the running shell script in place.
install -m 755 "$candidate/scripts/proxmox/manage.sh" /usr/local/lib/seekhunt/manage.sh.next
mv -f /usr/local/lib/seekhunt/manage.sh.next /usr/local/lib/seekhunt/manage.sh
if [[ -n "$old_release" ]]; then
  ln -sfnT "$old_release" "$APP_ROOT/previous.next"
  mv -Tf "$APP_ROOT/previous.next" "$APP_ROOT/previous"
fi
# Retain current + previous releases, and the three newest consistent state backups.
for release in "$APP_ROOT"/releases/*; do
  [[ -d "$release" ]] || continue
  if [[ "$release" != "$candidate" && "$release" != "$old_release" ]]; then
    rm -rf "$release"
  fi
done
mapfile -t backups < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | sort -r)
for ((index = 3; index < ${#backups[@]}; index++)); do
  rm -f "$BACKUP_ROOT/${backups[index]}"
done
# Avoid keeping a second copy of all downloaded npm packages on a small root disk.
rm -rf "$CACHE_ROOT/npm"
echo "SeekHunt ${commit:0:12} is running on HTTP port ${PORT} (workerd ${new_runtime})."
[[ -z "$backup" ]] || echo "Pre-update backup: $backup"
