#!/usr/bin/env bash
# License: MIT | https://github.com/stevenbuehner/SeekHunt/blob/proxmox/main/LICENSE
# Uses the Community Scripts LXC framework; this is an independent installer.
# Framework/template: Copyright (c) 2021-2026 community-scripts ORG, MIT.

export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/stevenbuehner/SeekHunt/proxmox/main"
# Pin the framework so unrelated upstream changes do not change this installer.
export COMMUNITY_SCRIPTS_CORE_URL="https://raw.githubusercontent.com/community-scripts/core/39ac4530299dd2c0d8c162a4bd7b1b9c826dd5c8"
_cs_bootstrap="$(curl -fsSL --connect-timeout 10 --max-time 90 "${COMMUNITY_SCRIPTS_CORE_URL}/core/build.func")" || exit 1
[[ -n "$_cs_bootstrap" ]] || exit 1
# shellcheck disable=SC1090
source /dev/stdin <<<"$_cs_bootstrap"

APP="SeekHunt"
var_tags="${var_tags:-game}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-6}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /usr/local/lib/seekhunt/manage.sh ]]; then
    msg_error "No SeekHunt installation found."
    exit 1
  fi
  /usr/local/lib/seekhunt/manage.sh update
  exit "$?"
}

start
build_container
description

msg_ok "SeekHunt is running at http://${IP}:8787"
msg_info "Point your HTTPS reverse proxy at this address and enable WebSocket forwarding."
