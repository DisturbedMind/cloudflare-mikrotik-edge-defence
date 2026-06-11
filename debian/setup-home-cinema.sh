#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/home-cinema.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/home-cinema.env"
  set +a
fi

STACK_DIR="${STACK_DIR:-/opt/home-cinema-edge}"
LAN_IP="${LAN_IP:-192.168.1.10}"
FEED_BIND_IP="${FEED_BIND_IP:-0.0.0.0}"
ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
LOCAL_PROXY_PORT="${LOCAL_PROXY_PORT:-18080}"
TUNNEL_NAME="${TUNNEL_NAME:-home-cinema}"
ZONE_NAME="${ZONE_NAME:-example.com}"
EMBY_HOSTNAME="${EMBY_HOSTNAME:-emby.example.com}"
STREAM_HOSTNAME="${STREAM_HOSTNAME:-stream.example.com}"
EMBY_UPSTREAM="${EMBY_UPSTREAM:-192.168.1.110:8096}"
STREAM_UPSTREAM="${STREAM_UPSTREAM:-192.168.1.118:8096}"
START_CLOUDFLARE_BOUNCER="${START_CLOUDFLARE_BOUNCER:-0}"
SETUP_TUNNEL="${SETUP_TUNNEL:-1}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-${CLOUDFLARED_TOKEN:-}}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run this script with sudo or as root"
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    die "Docker Compose was not found after installation"
  fi
}

run_compose() {
  local compose
  compose="$(compose_cmd)"
  (cd "${STACK_DIR}" && ${compose} "$@")
}

install_base_packages() {
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl debian-archive-keyring docker.io gnupg jq python3 systemd
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin || apt-get install -y docker-compose
  fi
  systemctl enable --now docker
}

install_cloudflared() {
  apt-get install -y ca-certificates curl gnupg
  mkdir -p --mode=0755 /usr/share/keyrings

  find /etc/apt/sources.list.d -type f -name '*.list' -print0 \
    | while IFS= read -r -d '' list_file; do
        if grep -q 'pkg.cloudflare.com/cloudflared' "${list_file}"; then
          rm -f "${list_file}"
        fi
      done

  rm -f /usr/share/keyrings/cloudflare-main.gpg
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg

  cat >/etc/apt/sources.list.d/cloudflared.list <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF

  if apt-get update && apt-get install -y cloudflared; then
    return 0
  fi

  echo "Cloudflare apt repository failed; falling back to latest official cloudflared .deb."
  rm -f /etc/apt/sources.list.d/cloudflared.list
  apt-get update || true
  local arch deb_path
  arch="$(dpkg --print-architecture)"
  deb_path="/tmp/cloudflared-linux-${arch}.deb"
  curl --location --fail --output "${deb_path}" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
  dpkg -i "${deb_path}" || apt-get install -f -y
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared install failed after apt and .deb fallback"
}

install_crowdsec() {
  mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg ]]; then
    curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey | gpg --dearmor >/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg
  fi
  cat >/etc/apt/sources.list.d/crowdsec_crowdsec.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main
deb-src [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main
EOF
  apt-get update
  apt-get install -y crowdsec crowdsec-cloudflare-worker-bouncer
}

install_stack_files() {
  install -d -m 0755 "${STACK_DIR}/nginx" "${STACK_DIR}/crowdsec" "${STACK_DIR}/feed" "${STACK_DIR}/feed/public" "${STACK_DIR}/logs/nginx"
  install -m 0644 "${SCRIPT_DIR}/docker-compose.yml" "${STACK_DIR}/docker-compose.yml"
  install -m 0644 "${SCRIPT_DIR}/nginx/home-cinema.conf" "${STACK_DIR}/nginx/home-cinema.conf"
  install -m 0644 "${SCRIPT_DIR}/crowdsec/home-cinema-nginx.yaml" "${STACK_DIR}/crowdsec/home-cinema-nginx.yaml"
  install -m 0755 "${SCRIPT_DIR}/feed/build-mikrotik-offenders.py" "${STACK_DIR}/feed/build-mikrotik-offenders.py"
  install -m 0755 "${SCRIPT_DIR}/repair-home-cinema.sh" "${STACK_DIR}/repair-home-cinema.sh"
  if [[ ! -f "${STACK_DIR}/feed/blocklists.json" ]]; then
    install -m 0644 "${SCRIPT_DIR}/feed/blocklists.json" "${STACK_DIR}/feed/blocklists.json"
  fi
  install -m 0644 "${SCRIPT_DIR}/feed/offenders.rsc" "${STACK_DIR}/feed/public/offenders.rsc"
  install -m 0644 "${SCRIPT_DIR}/feed/offenders.txt" "${STACK_DIR}/feed/public/offenders.txt"
  install -m 0644 "${SCRIPT_DIR}/feed/metadata.json" "${STACK_DIR}/feed/public/metadata.json"
  install -m 0644 "${SCRIPT_DIR}/feed/home-cinema-offenders.service" /etc/systemd/system/home-cinema-offenders.service
  install -m 0644 "${SCRIPT_DIR}/feed/home-cinema-offenders.timer" /etc/systemd/system/home-cinema-offenders.timer

  sed -i \
    -e "s#emby.example.com#${EMBY_HOSTNAME}#g" \
    -e "s#stream.example.com#${STREAM_HOSTNAME}#g" \
    -e "s#192.168.1.110:8096#${EMBY_UPSTREAM}#g" \
    -e "s#192.168.1.118:8096#${STREAM_UPSTREAM}#g" \
    "${STACK_DIR}/nginx/home-cinema.conf"

  cat >"${STACK_DIR}/.env" <<EOF
LAN_IP=${LAN_IP}
FEED_BIND_IP=${FEED_BIND_IP}
ROUTER_IP=${ROUTER_IP}
LOCAL_PROXY_PORT=${LOCAL_PROXY_PORT}
EMBY_HOSTNAME=${EMBY_HOSTNAME}
STREAM_HOSTNAME=${STREAM_HOSTNAME}
EMBY_UPSTREAM=${EMBY_UPSTREAM}
STREAM_UPSTREAM=${STREAM_UPSTREAM}
EOF
}

start_nginx() {
  run_compose up -d --force-recreate
}

configure_crowdsec() {
  install -m 0644 "${STACK_DIR}/crowdsec/home-cinema-nginx.yaml" /etc/crowdsec/acquis.d/home-cinema-nginx.yaml
  cscli collections install crowdsecurity/nginx crowdsecurity/base-http-scenarios crowdsecurity/http-cve || true
  systemctl enable --now crowdsec
  systemctl restart crowdsec
}

configure_feed_timer() {
  systemctl daemon-reload
  systemctl enable --now home-cinema-offenders.timer
  systemctl start home-cinema-offenders.service || true
}

ensure_seed_feed() {
  install -d -m 0755 "${STACK_DIR}/feed/public"
  if [[ ! -s "${STACK_DIR}/feed/public/offenders.rsc" ]]; then
    install -m 0644 "${SCRIPT_DIR}/feed/offenders.rsc" "${STACK_DIR}/feed/public/offenders.rsc"
  fi
  if [[ ! -s "${STACK_DIR}/feed/public/offenders.txt" ]]; then
    install -m 0644 "${SCRIPT_DIR}/feed/offenders.txt" "${STACK_DIR}/feed/public/offenders.txt"
  fi
  if [[ ! -s "${STACK_DIR}/feed/public/metadata.json" ]]; then
    install -m 0644 "${SCRIPT_DIR}/feed/metadata.json" "${STACK_DIR}/feed/public/metadata.json"
  fi
  chmod 0755 "${STACK_DIR}" "${STACK_DIR}/feed" "${STACK_DIR}/feed/public"
  chmod 0644 "${STACK_DIR}/feed/public/offenders.rsc" "${STACK_DIR}/feed/public/offenders.txt" "${STACK_DIR}/feed/public/metadata.json"
}

validate_feed_endpoint() {
  local health_code offenders_code

  docker exec home-cinema-nginx sh -lc 'test -r /usr/share/nginx/feed/offenders.rsc && grep -q home_cinema_offenders /usr/share/nginx/feed/offenders.rsc' \
    || die "Nginx container cannot read /usr/share/nginx/feed/offenders.rsc. Run ${STACK_DIR}/repair-home-cinema.sh and inspect Docker volume output."

  health_code="$(curl -sS -o /tmp/home-cinema-health.out -w '%{http_code}' "http://${LAN_IP}:8088/mikrotik/health" || true)"
  [[ "${health_code}" == "200" ]] || die "feed health endpoint returned HTTP ${health_code}; see ${STACK_DIR}/logs/nginx/feed-error.log"

  offenders_code="$(curl -sS -o /tmp/home-cinema-offenders.out -w '%{http_code}' "http://${LAN_IP}:8088/mikrotik/offenders.rsc" || true)"
  [[ "${offenders_code}" == "200" ]] || die "offenders.rsc endpoint returned HTTP ${offenders_code}; see ${STACK_DIR}/logs/nginx/feed-error.log and run ${STACK_DIR}/repair-home-cinema.sh"
}

configure_tunnel() {
  local tunnel_id credentials_src credentials_dst

  if [[ -n "${TUNNEL_TOKEN}" ]]; then
    echo "Installing remotely managed Cloudflare Tunnel service with provided token."
    if systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
      systemctl stop cloudflared || true
      cloudflared service uninstall || true
    fi
    cloudflared service install "${TUNNEL_TOKEN}"
    systemctl enable --now cloudflared
    systemctl restart cloudflared
    echo "Remote tunnel mode: configure public hostnames in Cloudflare Zero Trust to point to http://127.0.0.1:${LOCAL_PROXY_PORT}."
    return 0
  fi

  if ! cloudflared tunnel list --output json 2>/dev/null | jq -e --arg name "${TUNNEL_NAME}" '.[] | select(.name == $name)' >/dev/null; then
    echo "Creating Cloudflare tunnel '${TUNNEL_NAME}'. Complete browser login if prompted."
    cloudflared tunnel login
    cloudflared tunnel create "${TUNNEL_NAME}"
  fi

  tunnel_id="$(cloudflared tunnel list --output json | jq -r --arg name "${TUNNEL_NAME}" '.[] | select(.name == $name) | .id' | head -n1)"
  [[ -n "${tunnel_id}" && "${tunnel_id}" != "null" ]] || die "could not resolve tunnel id for ${TUNNEL_NAME}"

  cloudflared tunnel route dns "${TUNNEL_NAME}" "${EMBY_HOSTNAME}" || true
  cloudflared tunnel route dns "${TUNNEL_NAME}" "${STREAM_HOSTNAME}" || true

  install -d -m 0700 /etc/cloudflared
  credentials_src="/root/.cloudflared/${tunnel_id}.json"
  credentials_dst="/etc/cloudflared/${tunnel_id}.json"
  [[ -f "${credentials_src}" ]] || die "missing tunnel credentials at ${credentials_src}"
  install -m 0600 "${credentials_src}" "${credentials_dst}"

  cat >/etc/cloudflared/config.yml <<EOF
tunnel: ${tunnel_id}
credentials-file: ${credentials_dst}
protocol: quic
loglevel: info
ingress:
  - hostname: ${EMBY_HOSTNAME}
    service: http://127.0.0.1:${LOCAL_PROXY_PORT}
  - hostname: ${STREAM_HOSTNAME}
    service: http://127.0.0.1:${LOCAL_PROXY_PORT}
  - service: http_status:404
EOF

  if ! systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
    cloudflared --config /etc/cloudflared/config.yml service install
  fi
  systemctl enable --now cloudflared
  systemctl restart cloudflared
}

configure_cloudflare_bouncer() {
  local bouncer_key cfg
  cfg="/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml"

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo "CLOUDFLARE_API_TOKEN is not set; skipping Cloudflare Workers bouncer generation."
    return 0
  fi

  if [[ -f "${cfg}" ]]; then
    bouncer_key="$(awk '/^[[:space:]]*lapi_key:/ {print $2; exit}' "${cfg}" | tr -d '"' || true)"
  else
    bouncer_key=""
  fi

  if [[ -z "${bouncer_key}" || "${bouncer_key}" == "null" ]]; then
    bouncer_key="$(cscli bouncers add "cloudflare-worker-home-cinema-$(date +%Y%m%d%H%M%S)" -o raw)"
  fi

  crowdsec-cloudflare-worker-bouncer -g "${CLOUDFLARE_API_TOKEN}" -o "${cfg}"
  sed -i -E \
    -e "s#^([[:space:]]*lapi_key:[[:space:]]*).*#\\1${bouncer_key}#" \
    -e "s#^([[:space:]]*lapi_url:[[:space:]]*).*#\\1http://127.0.0.1:8080/#" \
    "${cfg}"

  echo "Review ${cfg} before starting the Cloudflare Workers bouncer."
  if [[ "${START_CLOUDFLARE_BOUNCER}" == "1" ]]; then
    systemctl enable --now crowdsec-cloudflare-worker-bouncer
    systemctl restart crowdsec-cloudflare-worker-bouncer
  fi
}

main() {
  need_root
  install_base_packages
  install_cloudflared
  install_crowdsec
  install_stack_files
  ensure_seed_feed
  start_nginx
  configure_crowdsec
  configure_feed_timer
  ensure_seed_feed
  start_nginx
  validate_feed_endpoint
  if [[ "${SETUP_TUNNEL}" == "1" ]]; then
    configure_tunnel
  else
    echo "Skipping Cloudflare Tunnel setup because SETUP_TUNNEL is not 1."
  fi
  configure_cloudflare_bouncer

  cat <<EOF

Home Cinema edge stack installed.

Checks:
  cd ${STACK_DIR} && $(compose_cmd) ps
  curl -I http://127.0.0.1:${LOCAL_PROXY_PORT} -H 'Host: ${EMBY_HOSTNAME}'
  curl -i http://${LAN_IP}:8088/mikrotik/health
  curl -i http://${LAN_IP}:8088/mikrotik/offenders.rsc
  ${STACK_DIR}/repair-home-cinema.sh
EOF
}

main "$@"
