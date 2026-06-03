package main

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	apkDownloadFilename = "ghostty-sharing.apk"
	apkGrantTTLSeconds  = 60.0
)

func resolveAPKPath(staticRoot string) string {
	if override := strings.TrimSpace(os.Getenv("GHOSTTY_RELAY_APK_PATH")); override != "" {
		return override
	}
	return filepath.Join(filepath.Dir(staticRoot), "apk", "app-release.apk")
}

func resolveWebBundlePath(staticRoot string) string {
	if override := strings.TrimSpace(os.Getenv("GHOSTTY_RELAY_WEB_BUNDLE_PATH")); override != "" {
		return override
	}
	return filepath.Join(filepath.Dir(staticRoot), "web-bundle", "dist.zip")
}

func minAPKVersionCode() int64 {
	raw := strings.TrimSpace(os.Getenv("GHOSTTY_RELAY_MIN_APK_VERSION_CODE"))
	if raw == "" {
		return 0
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		logEvent("min_apk_version_code_invalid", f("raw", raw))
		return 0
	}
	if v < 0 {
		return 0
	}
	return v
}

func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

// coercion helpers mirroring server.py's defensive type coercion.
func intField(m map[string]any, key string) int64 {
	if v, ok := m[key].(float64); ok {
		return int64(v)
	}
	return 0
}

func strFieldDefault(m map[string]any, key, def string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return def
	}
	if s, ok := v.(string); ok {
		return s
	}
	return toStr(v)
}

func strFieldStrictDefault(m map[string]any, key, def string) string {
	// Mirror "str(x) if isinstance(x,str) else def".
	if s, ok := m[key].(string); ok {
		return s
	}
	return def
}

func (s *server) handleAPKGrant(w http.ResponseWriter, r *http.Request, method string) {
	st := s.state
	if method != http.MethodPost {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	token := bearerToken(r)
	if token == "" {
		st.incMetric("auth_rejected_total")
		st.incMetric("apk_download_grant_rejected_total")
		writeJSON(w, r, 401, jsonError("missing bearer token"))
		return
	}
	if !st.isValidUserToken(token) {
		st.incMetric("auth_rejected_total")
		st.incMetric("apk_download_grant_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}
	grant := tokenURLSafe(16)
	st.mu.Lock()
	st.apkGrants[grant] = nowSec() + apkGrantTTLSeconds
	st.mu.Unlock()
	st.incMetric("apk_download_grant_total")
	writeJSON(w, r, 200, jsonBytes(map[string]any{"token": grant, "expires_in": int(apkGrantTTLSeconds)}))
}

func (s *server) handleAPKDownload(w http.ResponseWriter, r *http.Request, method string, query url.Values) {
	st := s.state
	if method != http.MethodGet {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}

	grant := firstQuery(query, "dl")
	if grant == "" {
		grant = firstQuery(query, "grant")
	}
	authorized := false
	if grant != "" {
		st.mu.Lock()
		deadline, present := st.apkGrants[grant]
		if present && deadline >= nowSec() {
			authorized = true
		} else if present {
			delete(st.apkGrants, grant)
		}
		st.mu.Unlock()
		if !authorized {
			st.incMetric("apk_download_rejected_total")
			writeJSON(w, r, 401, jsonError("invalid or expired grant"))
			return
		}
	} else {
		token := bearerToken(r)
		if token == "" {
			st.incMetric("auth_rejected_total")
			st.incMetric("apk_download_rejected_total")
			writeJSON(w, r, 401, jsonError("missing bearer token"))
			return
		}
		if !st.isValidUserToken(token) {
			st.incMetric("auth_rejected_total")
			st.incMetric("apk_download_rejected_total")
			writeJSON(w, r, 401, jsonError("invalid user token"))
			return
		}
	}

	apkPath := resolveAPKPath(s.config.StaticRoot)
	if !fileExists(apkPath) {
		st.incMetric("apk_download_rejected_total")
		logEvent("apk_download_missing", f("path", apkPath))
		writeJSON(w, r, 503, jsonError("apk_not_available"))
		return
	}
	body, err := os.ReadFile(apkPath)
	if err != nil {
		st.incMetric("apk_download_rejected_total")
		logEvent("apk_download_missing", f("path", apkPath))
		writeJSON(w, r, 503, jsonError("apk_not_available"))
		return
	}
	st.incMetric("apk_download_total")
	writeResponse(w, r, 200, body, "application/vnd.android.package-archive", map[string]string{
		"Content-Disposition": `attachment; filename="` + apkDownloadFilename + `"`,
		"Cache-Control":       "no-store",
	})
}

func (s *server) handleAPKVersion(w http.ResponseWriter, r *http.Request, method string) {
	if method != http.MethodGet {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	minCode := minAPKVersionCode()
	apkPath := resolveAPKPath(s.config.StaticRoot)
	versionPath := filepath.Join(filepath.Dir(apkPath), "version.json")

	unavailable := func() {
		writeJSON(w, r, 200, jsonBytes(map[string]any{
			"versionCode": 0, "versionName": "unknown", "available": false, "minVersionCode": minCode,
		}))
	}

	if !fileExists(versionPath) {
		unavailable()
		return
	}
	raw, err := os.ReadFile(versionPath)
	if err != nil {
		logEvent("apk_version_corrupt", f("path", versionPath))
		unavailable()
		return
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		logEvent("apk_version_corrupt", f("path", versionPath))
		unavailable()
		return
	}
	writeJSON(w, r, 200, jsonBytes(map[string]any{
		"versionCode":    intField(m, "versionCode"),
		"versionName":    strFieldStrictDefault(m, "versionName", "unknown"),
		"builtAt":        strFieldStrictDefault(m, "builtAt", ""),
		"available":      true,
		"minVersionCode": minCode,
	}))
}

func (s *server) handleWebManifest(w http.ResponseWriter, r *http.Request, method string) {
	if method != http.MethodGet {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	manifestPath := filepath.Join(s.config.StaticRoot, "manifest.json")

	unavailable := func() {
		writeJSON(w, r, 200, jsonBytes(map[string]any{"webVersion": "unknown", "available": false}))
	}

	if !fileExists(manifestPath) {
		unavailable()
		return
	}
	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		logEvent("web_manifest_corrupt", f("path", manifestPath))
		unavailable()
		return
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		logEvent("web_manifest_corrupt", f("path", manifestPath))
		unavailable()
		return
	}
	writeJSON(w, r, 200, jsonBytes(map[string]any{
		"webVersion":             strFieldDefault(m, "webVersion", "unknown"),
		"sha256":                 strFieldDefault(m, "sha256", ""),
		"sizeBytes":              intField(m, "sizeBytes"),
		"builtAt":                strFieldDefault(m, "builtAt", ""),
		"bundleUrl":              strFieldDefault(m, "bundleUrl", ""),
		"requiredApkVersionCode": intField(m, "requiredApkVersionCode"),
		"available":              true,
	}))
}

func (s *server) handleWebBundle(w http.ResponseWriter, r *http.Request, method string) {
	st := s.state
	if method != http.MethodGet {
		writeJSON(w, r, 405, jsonError("method not allowed"))
		return
	}
	token := bearerToken(r)
	if token == "" {
		st.incMetric("auth_rejected_total")
		st.incMetric("web_bundle_rejected_total")
		writeJSON(w, r, 401, jsonError("missing bearer token"))
		return
	}
	if !st.isValidUserToken(token) {
		st.incMetric("auth_rejected_total")
		st.incMetric("web_bundle_rejected_total")
		writeJSON(w, r, 401, jsonError("invalid user token"))
		return
	}
	bundlePath := resolveWebBundlePath(s.config.StaticRoot)
	if !fileExists(bundlePath) {
		st.incMetric("web_bundle_rejected_total")
		logEvent("web_bundle_missing", f("path", bundlePath))
		writeJSON(w, r, 503, jsonError("bundle_not_available"))
		return
	}
	body, err := os.ReadFile(bundlePath)
	if err != nil {
		st.incMetric("web_bundle_rejected_total")
		logEvent("web_bundle_missing", f("path", bundlePath))
		writeJSON(w, r, 503, jsonError("bundle_not_available"))
		return
	}
	st.incMetric("web_bundle_total")
	writeResponse(w, r, 200, body, "application/zip", map[string]string{
		"Content-Disposition": `attachment; filename="ghostty-web.zip"`,
		"Cache-Control":       "no-store",
	})
}
