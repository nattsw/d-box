#!/usr/bin/env bash
set -euo pipefail
repo="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
eval "$(sed -n '/^ts_port_for() {$/,/^}$/p' "$repo/d-box")"
DBOX_DIR="$(mktemp -d)"
trap 'rm -rf "$DBOX_DIR"' EXIT
APP_PORT=3000
TS_BASE_PORT=3001
ts_served_ports() { :; }
port_free_on_host() { [ "$1" != 3002 ]; }
unexpose_box() { printf 'unexpose\n' >> "$DBOX_DIR/actions"; }
remove_tailnet_proxy() { printf 'remove\n' >> "$DBOX_DIR/actions"; }
[ "$(ts_port_for first)" = 3001 ]
[ "$(ts_port_for first)" = 3001 ]
[ "$(ts_port_for second)" = 3003 ]
mkdir -p "$DBOX_DIR/state/legacy"
printf 3000 > "$DBOX_DIR/state/legacy/tailnet-port"
[ "$(ts_port_for legacy)" = 3004 ]
[ "$(cat "$DBOX_DIR/actions")" = $'unexpose\nremove' ]
[ "$(cat "$DBOX_DIR/state/legacy/tailnet-port")" = 3004 ]
TS_BASE_PORT=3000
[ "$(ts_port_for overridden)" = 3005 ]
printf 'Tailnet port tests passed\n'
