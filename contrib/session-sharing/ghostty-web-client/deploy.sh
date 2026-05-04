#!/usr/bin/env bash
# Build and rsync the session-sharing web client to the relay host.
#
# Usage:
#   ./deploy.sh                # npm run build + rsync to the defaults below
#   ./deploy.sh --dry-run      # preview what rsync would change
#   ./deploy.sh --skip-build   # rsync the existing dist/ as-is
#
# Override the target with environment variables:
#   DEPLOY_HOST=user@host \
#   DEPLOY_PATH=/srv/web-client/dist/ \
#     ./deploy.sh
#
# Defaults match the production relay (GHOSTTY_RELAY_STATIC_ROOT in
# /etc/ghostty-relay.env). The relay serves files directly off disk, so no
# service restart is needed after a successful sync.

set -euo pipefail

cd "$(dirname "$0")"

DEPLOY_HOST="${DEPLOY_HOST:-root@47.94.215.160}"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/ghostty-session-sharing/ghostty-web-client/dist/}"

skip_build=0
dry_run=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) skip_build=1 ;;
        --dry-run)    dry_run=1 ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ "$skip_build" -eq 0 ]]; then
    npm run build
fi

rsync_args=(-avz --delete)
if [[ "$dry_run" -eq 1 ]]; then
    rsync_args+=(--dry-run)
fi

rsync "${rsync_args[@]}" dist/ "$DEPLOY_HOST:$DEPLOY_PATH"
