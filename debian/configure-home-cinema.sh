#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/home-cinema.env"
ROUTER_TEMPLATE="${SCRIPT_DIR}/../routeros/home-cinema-router.rsc"
ROUTER_OUTPUT="${SCRIPT_DIR}/../routeros/home-cinema-router.generated.rsc"

prompt() {
  local name="$1"
  local label="$2"
  local default="$3"
  local secret="${4:-0}"
  local value

  if [[ "${secret}" == "1" ]]; then
    read -r -s -p "${label} [leave blank to skip]: " value
    echo
  else
    read -r -p "${label} [${default}]: " value
  fi

  if [[ -z "${value}" ]]; then
    value="${default}"
  fi

  printf -v "${name}" '%s' "${value}"
}

write_env() {
  umask 077
  cat >"${ENV_FILE}" <<EOF
STACK_DIR=$(shell_quote "${STACK_DIR}")
LAN_IP=$(shell_quote "${LAN_IP}")
FEED_BIND_IP=$(shell_quote "${FEED_BIND_IP}")
ROUTER_IP=$(shell_quote "${ROUTER_IP}")
LOCAL_PROXY_PORT=$(shell_quote "${LOCAL_PROXY_PORT}")
TUNNEL_NAME=$(shell_quote "${TUNNEL_NAME}")
ZONE_NAME=$(shell_quote "${ZONE_NAME}")
EMBY_HOSTNAME=$(shell_quote "${EMBY_HOSTNAME}")
STREAM_HOSTNAME=$(shell_quote "${STREAM_HOSTNAME}")
EMBY_UPSTREAM=$(shell_quote "${EMBY_UPSTREAM}")
STREAM_UPSTREAM=$(shell_quote "${STREAM_UPSTREAM}")
SETUP_TUNNEL=$(shell_quote "${SETUP_TUNNEL}")
TUNNEL_TOKEN=$(shell_quote "${TUNNEL_TOKEN}")
CLOUDFLARE_API_TOKEN=$(shell_quote "${CLOUDFLARE_API_TOKEN}")
START_CLOUDFLARE_BOUNCER=$(shell_quote "${START_CLOUDFLARE_BOUNCER}")
EOF
}

shell_quote() {
  local value="$1"
  printf '%q' "${value}"
}

generate_routeros() {
  sed \
    -e "s#192.168.1.10#${LAN_IP}#g" \
    -e "s#192.168.1.1#${ROUTER_IP}#g" \
    "${ROUTER_TEMPLATE}" >"${ROUTER_OUTPUT}"
  chmod 0600 "${ROUTER_OUTPUT}"
}

main() {
  echo "Home Cinema configuration form"
  echo

  prompt STACK_DIR "Install directory on Debian" "/opt/home-cinema-edge"
  prompt LAN_IP "Debian server LAN IP" "192.168.1.10"
  prompt FEED_BIND_IP "Feed bind IP, use 0.0.0.0 unless you know the LAN IP is assigned" "0.0.0.0"
  prompt ROUTER_IP "MikroTik router IP" "192.168.1.1"
  prompt LOCAL_PROXY_PORT "Local tunnel-to-Nginx port" "18080"
  prompt TUNNEL_NAME "Cloudflare Tunnel name" "home-cinema"
  prompt ZONE_NAME "Cloudflare zone/domain" "example.com"
  prompt EMBY_HOSTNAME "First public Emby hostname" "emby.example.com"
  prompt STREAM_HOSTNAME "Second public Emby hostname" "stream.example.com"
  prompt EMBY_UPSTREAM "First Emby upstream IP:port" "192.168.1.110:8096"
  prompt STREAM_UPSTREAM "Second Emby upstream IP:port" "192.168.1.118:8096"
  prompt SETUP_TUNNEL "Set up cloudflared service? 1=yes, 0=no" "1"
  prompt TUNNEL_TOKEN "Cloudflare Tunnel token" "" 1
  prompt CLOUDFLARE_API_TOKEN "Cloudflare API token for CrowdSec bouncer" "" 1
  prompt START_CLOUDFLARE_BOUNCER "Start Cloudflare bouncer immediately? 1=yes, 0=no" "0"

  write_env
  generate_routeros

  echo
  echo "Wrote:"
  echo "  ${ENV_FILE}"
  echo "  ${ROUTER_OUTPUT}"
  echo
  echo "Run:"
  echo "  sudo ./setup-home-cinema.sh"
  echo
  echo "Do not commit home-cinema.env or home-cinema-router.generated.rsc."
}

main "$@"
