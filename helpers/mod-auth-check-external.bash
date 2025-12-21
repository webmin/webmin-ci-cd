#!/usr/bin/env bash
# mod-auth-check-external.bash (https://github.com/webmin/webmin-ci-cd)
# Copyright Ilia Ross <ilia@webmin.dev>
# Licensed under the MIT License
#
# Validates basic credentials via remote endpoint for mod_authnz_external. Reads
# login and password from stdin; caches result in /dev/shm; exits 0 (allow) or 1
# (deny).

set -euo pipefail
umask 077

# Set input args from environment
readonly login="${USER:-}"
readonly password="${PASS:-}"
readonly client_ip="${AUTH_CLIENT_IP:-}"

# Defaults
ENDPOINT="${HTTP_AUTH_ENDPOINT:-}"  # required
TTL="${HTTP_AUTH_TTL:-10}"
CACHE_DIR="${HTTP_AUTH_CACHE_DIR:-/dev/shm/http_auth_cache}"

# Help
print_help() {
  cat <<EOF
Usage: $0 --endpoint URL [--ttl SECONDS] [--cache-dir DIR]
  --endpoint   Required auth check URL (e.g. https://example.com/check/)
  --ttl        Optional cache TTL seconds (default: ${TTL})
  --cache-dir  Optional cache directory (default: ${CACHE_DIR})
  --help       Show this help
EOF
}

# Parse args
while (( "$#" )); do
  case "$1" in
    --endpoint)   ENDPOINT="${2:-}"; shift 2 ;;
    --ttl)        TTL="${2:-}"; shift 2 ;;
    --cache-dir)  CACHE_DIR="${2:-}"; shift 2 ;;
    --help)       print_help; exit 0 ;;
    --) shift; break ;;
    *)  echo "Unknown option: $1" >&2; print_help; exit 2 ;;
  esac
done

# Validate
[[ -n "${ENDPOINT}" ]] || { echo "Error: --endpoint is required." >&2; exit 1; }
[[ "${TTL}" =~ ^[0-9]+$ ]] || { echo "Error: TTL must be an integer." >&2; exit 1; }

# Cache setup
mkdir -p "${CACHE_DIR}"
chmod 700 "${CACHE_DIR}" || true

# Key includes endpoint to avoid cross-endpoint mixing
key="$(printf '%s|%s:%s' "${ENDPOINT}" "${login}" "${password}" | sha256sum | awk '{print $1}')"
cache="${CACHE_DIR}/${key}"
lock="${CACHE_DIR}/${key}.lock"
now="$(date +%s)"

fresh_cache() {
  [[ -f "${cache}" ]] || return 1
  mtime="$(stat -c %Y "${cache}" 2>/dev/null || echo 0)"
  age=$(( now - mtime ))
  (( age >= 0 && age < TTL ))
}

# Use cache if fresh
if fresh_cache; then
  rc="$(cat "${cache}" 2>/dev/null || echo 1)"
  exit "${rc:-1}"
fi

# When the cache is missing, lock it while it's being fetched, and others should
# wait
exec 9> "${lock}" || true
flock -w 5 9 || true

# Re-check inside lock to avoid double fetching
if fresh_cache; then
  rc="$(cat "${cache}" 2>/dev/null || echo 1)"
  exit "${rc:-1}"
fi

# Actual remote check
host="$(printf '%s' "${ENDPOINT}" | awk -F/ '{print $3}')"
netrc="$(mktemp -p /dev/shm .httpauthcheck.XXXXXX)"
trap 'rm -f "${netrc}"' EXIT
chmod 600 "${netrc}"
printf 'machine %s login %s password %s\n' "${host}" "${login}" "${password}" > "${netrc}"

# Get real client IP: X-Forwarded-For first, then IP, then REMOTE_ADDR
status="$(curl -sS -o /dev/null -w '%{http_code}' \
               --netrc-file "${netrc}" \
               -H "X-Auth-IP: ${client_ip}" \
               -H "X-Auth-Secret: SECRET" \
               --connect-timeout 3 --max-time 8 \
               "${ENDPOINT}" || true)"

rc=1
[[ "$status" =~ ^2 ]] && rc=0

# Write cache
tmp="${cache}.$$"
printf '%s\n' "${rc}" > "${tmp}" && mv -f "${tmp}" "${cache}"

exit "${rc}"
