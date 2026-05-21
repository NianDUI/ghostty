#!/usr/bin/env bash
# Build a signed release APK and rsync it to the relay host so the
# /api/app/android endpoint can serve it.
#
# Usage:
#   ./build-and-deploy-apk.sh               # full build + push
#   ./build-and-deploy-apk.sh --skip-build  # rsync the existing APK as-is
#   ./build-and-deploy-apk.sh --dry-run     # preview rsync, no upload
#   ./build-and-deploy-apk.sh --local-only  # build + sign, skip upload
#
# Requires (all gitignored):
#   - deploy.env          DEPLOY_HOST, DEPLOY_PATH, APK_REMOTE_DIR
#   - android/keystore/credentials.env (auto-sourced)
#
# By convention APK_REMOTE_DIR sits next to the web dist; e.g. if
# DEPLOY_PATH=/opt/ghostty-session-sharing/ghostty-web-client/dist/
# then APK_REMOTE_DIR=/opt/ghostty-session-sharing/ghostty-web-client/apk/
# The relay reads <static_root>.parent/apk/app-release.apk by default.

set -euo pipefail

cd "$(dirname "$0")"

skip_build=0
dry_run=0
local_only=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) skip_build=1 ;;
        --dry-run)    dry_run=1 ;;
        --local-only) local_only=1 ;;
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
APK_REMOTE_DIR="${APK_REMOTE_DIR:-}"

if [[ "$local_only" -eq 0 ]]; then
    if [[ -z "$DEPLOY_HOST" || -z "$APK_REMOTE_DIR" ]]; then
        cat >&2 <<'EOF'
build-and-deploy-apk.sh: missing DEPLOY_HOST or APK_REMOTE_DIR.
  Put them in deploy.env, or pass --local-only to skip upload.
  Example deploy.env entry:
      APK_REMOTE_DIR="/opt/ghostty-session-sharing/ghostty-web-client/apk/"
EOF
        exit 2
    fi
fi

# JDK 21 is required by Capacitor 8 / AGP 8.x. The default JDK on this
# machine is 26, which Gradle rejects with a cryptic Kotlin error.
if [[ -z "${JAVA_HOME:-}" || "${JAVA_HOME}" != *temurin-21* ]]; then
    candidate="/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"
    if [[ -d "$candidate" ]]; then
        export JAVA_HOME="$candidate"
        export PATH="$JAVA_HOME/bin:$PATH"
    else
        echo "JAVA_HOME is not JDK 21 and $candidate is missing." >&2
        echo "Install temurin@21 (brew install --cask temurin@21) or export JAVA_HOME manually." >&2
        exit 2
    fi
fi

keystore_env="android/keystore/credentials.env"
if [[ ! -f "$keystore_env" ]]; then
    cat >&2 <<EOF
$keystore_env not found.
  Run the keystore bootstrap first (see android/keystore/README or
  regenerate with keytool). The release build needs:
    GHOSTTY_KEYSTORE_PATH GHOSTTY_KEYSTORE_PASSWORD
    GHOSTTY_KEY_ALIAS     GHOSTTY_KEY_PASSWORD
EOF
    exit 2
fi
# shellcheck disable=SC1090
source "$keystore_env"

apk_path="android/app/build/outputs/apk/release/app-release.apk"

if [[ "$skip_build" -eq 0 ]]; then
    npm run android:build

    # ./gradlew assembleRelease honours the signingConfigs.release block
    # in android/app/build.gradle, which reads the GHOSTTY_KEYSTORE_* env
    # vars sourced above.
    (
        cd android
        ./gradlew assembleRelease
    )
fi

if [[ ! -f "$apk_path" ]]; then
    echo "expected APK at $apk_path but it is missing" >&2
    exit 3
fi

echo "Signed APK: $apk_path ($(du -h "$apk_path" | cut -f1))"

if [[ "$local_only" -eq 1 ]]; then
    exit 0
fi

# Upload as app-release.apk into APK_REMOTE_DIR. The relay reads this
# exact filename (see resolve_apk_path in relay/server.py).
rsync_args=(-avz)
if [[ "$dry_run" -eq 1 ]]; then
    rsync_args+=(--dry-run)
fi

rsync "${rsync_args[@]}" "$apk_path" "$DEPLOY_HOST:${APK_REMOTE_DIR%/}/app-release.apk"

echo "Done. Verify with:"
echo "  curl -fsS -H 'Authorization: Bearer <token>' \\"
echo "    https://<relay-host>/api/app/android -o /tmp/app.apk && ls -lh /tmp/app.apk"
