#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/home-cinema-edge}"
LAN_IP="${LAN_IP:-192.168.1.10}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    die "Docker Compose is not installed. Install docker-compose-plugin or docker-compose."
  fi
}

run_compose() {
  local compose
  compose="$(compose_cmd)"
  (cd "${STACK_DIR}" && ${compose} "$@")
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run this script with sudo or as root"
  fi
}

write_seed_feed() {
  install -d -m 0755 "${STACK_DIR}/feed/public"
  if [[ ! -s "${STACK_DIR}/feed/public/offenders.rsc" ]]; then
    printf '%s\n' \
      '# Seed Home Cinema MikroTik offender feed' \
      '/ip firewall address-list remove [find list="home_cinema_offenders" comment="home-cinema-feed"]' \
      >"${STACK_DIR}/feed/public/offenders.rsc"
  fi
  if [[ ! -s "${STACK_DIR}/feed/public/offenders.txt" ]]; then
    printf '%s\n' '# Seed feed' >"${STACK_DIR}/feed/public/offenders.txt"
  fi
  if [[ ! -s "${STACK_DIR}/feed/public/metadata.json" ]]; then
    printf '%s\n' '{"entries":0,"seed":true}' >"${STACK_DIR}/feed/public/metadata.json"
  fi
  chmod 0755 "${STACK_DIR}" "${STACK_DIR}/feed" "${STACK_DIR}/feed/public"
  chmod 0644 "${STACK_DIR}/feed/public/offenders.rsc" "${STACK_DIR}/feed/public/offenders.txt" "${STACK_DIR}/feed/public/metadata.json"
}

repair_nginx_feed_locations() {
  local cfg="${STACK_DIR}/nginx/home-cinema.conf"
  [[ -f "${cfg}" ]] || die "${cfg} does not exist"

  if grep -q 'try_files /offenders.rsc' "${cfg}"; then
    cp "${cfg}" "${cfg}.bak.$(date +%Y%m%d%H%M%S)"
    python3 - "${cfg}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

replacements = {
    r'location = /mikrotik/offenders\.rsc \{.*?\n    \}': '''location = /mikrotik/offenders.rsc {
        alias /usr/share/nginx/feed/offenders.rsc;
        default_type text/plain;
        add_header Cache-Control "no-store";
    }''',
    r'location = /mikrotik/offenders\.txt \{.*?\n    \}': '''location = /mikrotik/offenders.txt {
        alias /usr/share/nginx/feed/offenders.txt;
        default_type text/plain;
        add_header Cache-Control "no-store";
    }''',
    r'location = /mikrotik/metadata\.json \{.*?\n    \}': '''location = /mikrotik/metadata.json {
        alias /usr/share/nginx/feed/metadata.json;
        default_type application/json;
        add_header Cache-Control "no-store";
    }''',
}

for pattern, repl in replacements.items():
    text = re.sub(pattern, repl, text, flags=re.S)

path.write_text(text)
PY
  fi
}

main() {
  need_root
  cd "${STACK_DIR}" || die "${STACK_DIR} does not exist"
  write_seed_feed
  repair_nginx_feed_locations

  echo "Using Compose: $(compose_cmd)"
  run_compose down
  run_compose up -d --force-recreate

  echo
  echo "Container feed mount:"
  docker exec home-cinema-nginx sh -lc 'ls -la /usr/share/nginx/feed && echo "---" && cat /usr/share/nginx/feed/offenders.rsc'

  echo
  echo "Active Nginx feed server:"
  docker exec home-cinema-nginx nginx -T 2>/dev/null | awk '/listen 8088/{flag=1} flag{print} flag && /^}/{exit}'

  echo
  echo "HTTP checks:"
  curl -i "http://${LAN_IP}:8088/mikrotik/health"
  curl -i "http://${LAN_IP}:8088/mikrotik/offenders.rsc"

  echo
  echo "Recent feed logs:"
  tail -n 20 "${STACK_DIR}/logs/nginx/feed-access.log" 2>/dev/null || true
  tail -n 20 "${STACK_DIR}/logs/nginx/feed-error.log" 2>/dev/null || true
}

main "$@"
