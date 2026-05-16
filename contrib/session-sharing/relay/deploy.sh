#!/usr/bin/env bash
# Rsync the relay's server.py to the production host and bounce the
# systemd service. Mirrors the workflow we use for the web client
# (`ghostty-web-client/deploy.sh`).
#
# Usage:
#   ./deploy.sh                 # rsync server.py + restart service
#   ./deploy.sh --dry-run       # preview what rsync would change, no restart
#   ./deploy.sh --skip-restart  # rsync only, leave the running service alone
#   ./deploy.sh --all           # rsync the whole relay/ tree (excludes tests,
#                                 docs, __pycache__) instead of just server.py
#
# The deploy target is read from a sibling `deploy.env` file (gitignored)
# OR from the environment. The repo ships a `deploy.env.example`; copy
# it once and fill in your real values:
#
#   cp deploy.env.example deploy.env
#   $EDITOR deploy.env
#
# deploy.env recognises:
#   DEPLOY_HOST    ssh target, e.g. root@relay.example.com
#   DEPLOY_PATH    absolute path on the host that already contains
#                  server.py, e.g. /opt/ghostty-session-sharing/...
#                  /contrib/session-sharing/relay/
#   SERVICE_NAME   systemd unit to restart (default: ghostty-relay)
#
# The ssh user must be root or have NOPASSWD sudo for systemctl. The
# script issues `systemctl restart "$SERVICE_NAME"` unmodified.

set -euo pipefail

cd "$(dirname "$0")"

dry_run=0
skip_restart=0
sync_all=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)      dry_run=1 ;;
        --skip-restart) skip_restart=1 ;;
        --all)          sync_all=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ -f deploy.env ]]; then
    # shellcheck disable=SC1091
    source ./deploy.env
fi

DEPLOY_HOST="${DEPLOY_HOST:-}"
DEPLOY_PATH="${DEPLOY_PATH:-}"
SERVICE_NAME="${SERVICE_NAME:-ghostty-relay}"

if [[ -z "$DEPLOY_HOST" || -z "$DEPLOY_PATH" ]]; then
    cat >&2 <<'EOF'
deploy.sh: missing DEPLOY_HOST or DEPLOY_PATH.
  Either copy deploy.env.example to deploy.env and fill in the real
  values, or run with the variables set inline:
      DEPLOY_HOST=root@host \
      DEPLOY_PATH=/opt/.../relay/ \
      ./deploy.sh
EOF
    exit 2
fi

rsync_args=(-avz --checksum)
if [[ "$dry_run" -eq 1 ]]; then
    rsync_args+=(--dry-run)
fi

if [[ "$sync_all" -eq 1 ]]; then
    # Whole tree, but skip developer-side artefacts and one-shot setup
    # docs that don't belong in the running service's directory.
    rsync_args+=(
        --exclude=__pycache__/
        --exclude=*.pyc
        --exclude=deploy/
        --exclude=deploy.sh
        --exclude=deploy.env
        --exclude=deploy.env.example
        --exclude=DEPLOY.md
        --exclude=README.md
        --exclude=load_test.py
        --exclude=smoke_test.py
        --exclude=.gitignore
    )
    rsync "${rsync_args[@]}" ./ "$DEPLOY_HOST:$DEPLOY_PATH"
else
    rsync "${rsync_args[@]}" server.py "$DEPLOY_HOST:$DEPLOY_PATH"
fi

if [[ "$dry_run" -eq 1 || "$skip_restart" -eq 1 ]]; then
    echo "skipping service restart (dry-run=$dry_run, skip-restart=$skip_restart)"
    exit 0
fi

# shellcheck disable=SC2029
ssh "$DEPLOY_HOST" "systemctl restart $SERVICE_NAME && systemctl is-active $SERVICE_NAME"
echo "deployed and restarted $SERVICE_NAME on $DEPLOY_HOST"
