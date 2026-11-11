#!/usr/bin/env bash
# License: MIT | https://github.com/stevenbuehner/SeekHunt/blob/proxmox/main/LICENSE
# Framework/template: Copyright (c) 2021-2026 community-scripts ORG, MIT.

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

ensure_dependencies ca-certificates curl jq tar xz-utils libatomic1
NODE_VERSION="24" NODE_COREPACK_ENABLE="0" setup_nodejs

msg_info "Installing SeekHunt from proxmox/main"
_seekhunt_manager="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
  "${COMMUNITY_SCRIPTS_URL}/scripts/proxmox/manage.sh")" || exit 1
[[ -n "$_seekhunt_manager" ]] || exit 1
bash -c "$_seekhunt_manager" -- install
msg_ok "Installed SeekHunt"

motd_ssh
customize
