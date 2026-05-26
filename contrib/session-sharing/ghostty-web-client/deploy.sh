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

# Generate dist/manifest.json + sibling web-bundle/dist.zip so the
# relay can serve both: /api/web/manifest.json (manifest) and
# /api/web/bundle (zip). Client-side OTA (Capacitor plugin) downloads
# the zip, verifies sha256 against manifest, extracts under filesDir/,
# then calls Capacitor's built-in WebView.setServerBasePath.
#
# Building manifest at deploy time (not vite build time) means the
# version always reflects what's actually being shipped, including
# --skip-build re-pushes of an existing dist.
if git -C "$(pwd)" rev-parse --git-dir >/dev/null 2>&1; then
    web_version="$(git rev-parse --short=8 HEAD)"
    if git status --porcelain | head -n1 | read -r _; then
        web_version="${web_version}-dirty"
    fi
else
    web_version="dev-$(date +%s)"
fi

# Build the zip first so the manifest's sha256 matches the bytes the
# Android plugin will verify after download. Storing the zip in a
# sibling dir (web-bundle/) keeps dist/ unchanged — relay treats dist/
# as the SPA root and would otherwise serve dist.zip as a static file.
bundle_dir="web-bundle"
mkdir -p "$bundle_dir"
rm -f "$bundle_dir/dist.zip"
# -X drops file timestamps + permission bits beyond what's strictly
# needed; the zip layout is stable across hosts as long as `find` order
# is. -q because the rsync output below is what we want users to see.
(
    cd dist
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 zip -qX "../$bundle_dir/dist.zip"
)
bundle_sha="$(shasum -a 256 "$bundle_dir/dist.zip" | awk '{print $1}')"
bundle_bytes="$(wc -c <"$bundle_dir/dist.zip" | tr -d ' ')"

cat >dist/manifest.json <<EOF
{
  "webVersion": "$web_version",
  "sha256": "$bundle_sha",
  "sizeBytes": $bundle_bytes,
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bundleUrl": "/api/web/bundle"
}
EOF
echo "Web manifest: version=$web_version sha256=${bundle_sha:0:12}… size=${bundle_bytes}B"

rsync_args=(-avz --delete)
if [[ "$dry_run" -eq 1 ]]; then
    rsync_args+=(--dry-run)
fi

rsync "${rsync_args[@]}" dist/ "$DEPLOY_HOST:$DEPLOY_PATH"

# Ship the bundle to a sibling dir on the relay host. DEPLOY_PATH
# typically ends in `/dist/` — strip that to get the parent, then
# append `/web-bundle/`. mirrors the APK layout.
deploy_parent="${DEPLOY_PATH%/}"
deploy_parent="${deploy_parent%/dist}"
bundle_remote="${deploy_parent}/web-bundle/"
# rsync the zip without --delete so a stale bundle from a parallel
# deploy isn't yanked out from under in-flight downloads. The relay
# always serves whichever file is present at request time.
rsync_bundle_args=(-avz)
if [[ "$dry_run" -eq 1 ]]; then
    rsync_bundle_args+=(--dry-run)
fi
rsync "${rsync_bundle_args[@]}" "$bundle_dir/dist.zip" "$DEPLOY_HOST:$bundle_remote"
