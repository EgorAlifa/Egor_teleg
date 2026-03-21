#!/usr/bin/env bash
# deploy-all.sh — Deploy MTProto proxy then admin panel in one command.
# Usage: ./deploy-all.sh [--secret <secret>] [--port <port>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\033[1;34m[1/2]\033[0m Deploying MTProto proxy ..."
bash "$SCRIPT_DIR/deploy-mtproto.sh" "$@"

echo ""
echo -e "\033[1;34m[2/2]\033[0m Deploying admin panel ..."
bash "$SCRIPT_DIR/deploy-admin.sh"

echo ""
echo -e "\033[1;32mAll done.\033[0m  Admin panel → http://$(hostname -I | awk '{print $1}'):8080/"
