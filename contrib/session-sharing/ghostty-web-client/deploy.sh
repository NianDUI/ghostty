#!/usr/bin/env bash
# Build and rsync the session-sharing web client to the relay host.
#
# Usage:
#   ./deploy.sh                # npm run build + rsync to the configured target
#   ./deploy.sh --dry-run      # preview what rsync would change
#   ./deploy.sh --skip-build   # rsync the existing dist/ as-is
#
# The deploy target is read from a sibling `deploy.env` file (gitignored)
# OR from the environment. The repo ships a `deploy.env.example`; copy
# it once and fill in your real DEPLOY_HOST / DEPLOY_PATH:
#
#   cp deploy.env.example deploy.env
#   $EDITOR deploy.env
#
# Or pass them inline:
#
#   DEPLOY_HOST=user@host DEPLOY_PATH=/srv/web/dist/ ./deploy.sh
#
# The relay serves files directly off disk, so no service restart is
# needed after a successful sync.

set -euo pipefail

cd "$(dirname "$0")"

skip_build=0
dry_run=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) skip_build=1 ;;
        --dry-run)    dry_run=1 ;;
        -h|--help)
            sed -n '2,21p' "$0"
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

if [[ -z "$DEPLOY_HOST" || -z "$DEPLOY_PATH" ]]; then
    cat >&2 <<'EOF'
deploy.sh: missing DEPLOY_HOST or DEPLOY_PATH.
  Either copy deploy.env.example to deploy.env and fill in the real
  values, or run with the variables set inline:
      DEPLOY_HOST=user@host DEPLOY_PATH=/srv/web/dist/ ./deploy.sh
EOF
    exit 2
fi

if [[ "$skip_build" -eq 0 ]]; then
    npm run build
fi

rsync_args=(-avz --delete)
if [[ "$dry_run" -eq 1 ]]; then
    rsync_args+=(--dry-run)
fi

rsync "${rsync_args[@]}" dist/ "$DEPLOY_HOST:$DEPLOY_PATH"
