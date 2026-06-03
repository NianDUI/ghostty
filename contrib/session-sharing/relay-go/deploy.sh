#!/usr/bin/env bash
# Build the Go relay for the target host's architecture, rsync the compiled
# `ghostty-relay` binary to the production host, and bounce the systemd
# service. Mirrors the Python relay's deploy.sh (and the web client's
# `ghostty-web-client/deploy.sh`); the only real difference is that we ship a
# compiled binary instead of `server.py`.
#
# Usage:
#   ./deploy.sh                 # cross-compile + rsync binary + restart service
#   ./deploy.sh --dry-run       # build, then preview what rsync would change
#                                 (no restart)
#   ./deploy.sh --skip-restart  # build + rsync only, leave the service alone
#   ./deploy.sh --no-build      # skip the go build; rsync the pre-built binary
#                                 already sitting next to this script
#   ./deploy.sh --all           # rsync the whole relay-go/ tree (source +
#                                 binary, excludes deploy/ tooling & docs)
#                                 instead of just the binary
#
# ── Binary architecture (the #1 Go-specific footgun) ──────────────────────
# The Python relay rsync'd a .py file, so the host's CPU architecture never
# mattered. The Go relay ships a *compiled binary*, so it MUST match the
# production host's OS/arch or it won't even exec ("Exec format error").
# Production hosts are almost always linux/amd64, while you are likely on
# macos/arm64. This script therefore cross-compiles by default:
#
#     GOOS=linux GOARCH=amd64 go -C relay-go build -o ghostty-relay .
#
# Override the target via DEPLOY_GOOS / DEPLOY_GOARCH (e.g. linux/arm64 for
# an ARM VPS). Use --no-build only if you have already produced a binary for
# the correct target — a stray macos/arm64 binary will fail to start on the
# server with a confusing systemd "status=203/EXEC" or "Exec format error".
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
#   DEPLOY_PATH    absolute path on the host that already contains the
#                  ghostty-relay binary, e.g. /opt/ghostty-session-sharing/...
#                  /contrib/session-sharing/relay-go/
#   SERVICE_NAME   systemd unit to restart (default: ghostty-relay)
#
# Cross-compile target (optional, env or deploy.env):
#   DEPLOY_GOOS    default: linux
#   DEPLOY_GOARCH  default: amd64
#
# The ssh user must be root or have NOPASSWD sudo for systemctl. The
# script issues `systemctl restart "$SERVICE_NAME"` unmodified.

set -euo pipefail

cd "$(dirname "$0")"

dry_run=0
skip_restart=0
sync_all=0
no_build=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)      dry_run=1 ;;
        --skip-restart) skip_restart=1 ;;
        --all)          sync_all=1 ;;
        --no-build)     no_build=1 ;;
        -h|--help)
            sed -n '2,63p' "$0"
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
DEPLOY_GOOS="${DEPLOY_GOOS:-linux}"
DEPLOY_GOARCH="${DEPLOY_GOARCH:-amd64}"

if [[ -z "$DEPLOY_HOST" || -z "$DEPLOY_PATH" ]]; then
    cat >&2 <<'EOF'
deploy.sh: missing DEPLOY_HOST or DEPLOY_PATH.
  Either copy deploy.env.example to deploy.env and fill in the real
  values, or run with the variables set inline:
      DEPLOY_HOST=root@host \
      DEPLOY_PATH=/opt/.../relay-go/ \
      ./deploy.sh
EOF
    exit 2
fi

# Build the binary for the production target unless told otherwise. We invoke
# `go -C .` so the module is resolved from this directory regardless of the
# caller's cwd.
if [[ "$no_build" -eq 0 ]]; then
    echo "building ghostty-relay for ${DEPLOY_GOOS}/${DEPLOY_GOARCH}..."
    GOOS="$DEPLOY_GOOS" GOARCH="$DEPLOY_GOARCH" CGO_ENABLED=0 \
        go -C . build -o ghostty-relay .
else
    echo "--no-build: reusing existing ./ghostty-relay (ensure it is ${DEPLOY_GOOS}/${DEPLOY_GOARCH})"
fi

if [[ ! -f ghostty-relay ]]; then
    echo "deploy.sh: ./ghostty-relay not found (build failed or --no-build with no binary)" >&2
    exit 1
fi

rsync_args=(-avz --checksum)
if [[ "$dry_run" -eq 1 ]]; then
    rsync_args+=(--dry-run)
fi

if [[ "$sync_all" -eq 1 ]]; then
    # Whole tree, but skip developer-side artefacts and one-shot setup
    # docs/tooling that don't belong in the running service's directory.
    rsync_args+=(
        --exclude=deploy/
        --exclude=deploy.sh
        --exclude=deploy.env
        --exclude=deploy.env.example
        --exclude=DEPLOY.md
        --exclude=README.md
        --exclude=.gitignore
    )
    rsync "${rsync_args[@]}" ./ "$DEPLOY_HOST:$DEPLOY_PATH"
else
    rsync "${rsync_args[@]}" ghostty-relay "$DEPLOY_HOST:$DEPLOY_PATH"
fi

if [[ "$dry_run" -eq 1 || "$skip_restart" -eq 1 ]]; then
    echo "skipping service restart (dry-run=$dry_run, skip-restart=$skip_restart)"
    exit 0
fi

# shellcheck disable=SC2029
ssh "$DEPLOY_HOST" "systemctl restart $SERVICE_NAME && systemctl is-active $SERVICE_NAME"
echo "deployed and restarted $SERVICE_NAME on $DEPLOY_HOST"
