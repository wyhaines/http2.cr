#!/usr/bin/env bash
set -euo pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
certificate="$project_root/spec/fixtures/tls/example.crt"
private_key="$project_root/spec/fixtures/tls/example.key"
cleartext_port=${NGHTTP2_CLEARTEXT_PORT:-18080}
tls_port=${NGHTTP2_TLS_PORT:-18443}
temporary_root=$(mktemp -d)
document_root="$temporary_root/htdocs"
cleartext_log="$temporary_root/nghttp2-cleartext.log"
tls_log="$temporary_root/nghttp2-tls.log"
cleartext_pid=
tls_pid=

cleanup() {
  local status=$?

  if [[ -n "$cleartext_pid" ]]; then
    kill "$cleartext_pid" 2>/dev/null || true
    wait "$cleartext_pid" 2>/dev/null || true
  fi
  if [[ -n "$tls_pid" ]]; then
    kill "$tls_pid" 2>/dev/null || true
    wait "$tls_pid" 2>/dev/null || true
  fi

  if [[ $status -ne 0 ]]; then
    tail -n 240 "$cleartext_log" >&2 || true
    tail -n 240 "$tls_log" >&2 || true
  fi
  rm -rf -- "$temporary_root"
  exit "$status"
}
trap cleanup EXIT INT TERM

if ! command -v nghttpd >/dev/null 2>&1; then
  echo "nghttpd is required for the interoperability suite" >&2
  exit 1
fi

mkdir -p "$document_root"
printf 'hello from nghttp2\n' >"$document_root/hello.txt"
dd if=/dev/zero of="$document_root/large.bin" bs=1024 count=512 status=none

common_options=(
  --address=127.0.0.1
  --htdocs="$document_root"
  --verbose
  --header-table-size=1024
  --encoder-header-table-size=1024
  --max-concurrent-streams=100
  --window-bits=14
  --connection-window-bits=14
  --padding=31
  --echo-upload
  "--trailer=x-nghttp2-trailer: received"
)

nghttpd "${common_options[@]}" --no-tls "$cleartext_port" \
  >"$cleartext_log" 2>&1 &
cleartext_pid=$!
nghttpd "${common_options[@]}" "$tls_port" "$private_key" "$certificate" \
  >"$tls_log" 2>&1 &
tls_pid=$!

for _ in {1..100}; do
  if ! kill -0 "$cleartext_pid" 2>/dev/null ||
     ! kill -0 "$tls_pid" 2>/dev/null; then
    echo "an nghttp2 server exited during startup" >&2
    exit 1
  fi
  if grep -q "listen" "$cleartext_log" &&
     grep -q "listen" "$tls_log"; then
    break
  fi
  sleep 0.05
done

if ! grep -q "listen" "$cleartext_log" ||
   ! grep -q "listen" "$tls_log"; then
  echo "timed out waiting for nghttp2 servers" >&2
  exit 1
fi

export NGHTTP2_CLEARTEXT_PORT="$cleartext_port"
export NGHTTP2_TLS_PORT="$tls_port"
export NGHTTP2_CERTIFICATE="$certificate"
export NGHTTP2_INTEROP=1

cd "$project_root"
crystal spec "$@" spec/interop/nghttp2_integration_spec.cr -t -s

for _ in {1..40}; do
  if grep -q "recv RST_STREAM frame" "$cleartext_log" &&
     grep -q "recv GOAWAY frame" "$cleartext_log" &&
     grep -q "recv GOAWAY frame" "$tls_log"; then
    exit 0
  fi
  sleep 0.05
done

echo "nghttp2 did not observe the expected RST_STREAM and GOAWAY frames" >&2
exit 1
