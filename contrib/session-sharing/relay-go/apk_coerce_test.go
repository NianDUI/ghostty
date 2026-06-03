package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ---- apk version parsing + defensive field coercion ----

func TestAPKVersionParsed(t *testing.T) {
	dir := t.TempDir()
	apkPath := filepath.Join(dir, "app-release.apk")
	if err := os.WriteFile(apkPath, []byte("fake-apk"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "version.json"),
		[]byte(`{"versionCode":42,"versionName":"1.2.3","builtAt":"2026-01-01T00:00:00Z"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GHOSTTY_RELAY_APK_PATH", apkPath)

	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/app/version", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	var m map[string]any
	resp.decode(t, &m)
	if v, _ := m["versionCode"].(float64); int(v) != 42 {
		t.Errorf("versionCode=%v, want 42", m["versionCode"])
	}
	if m["versionName"] != "1.2.3" {
		t.Errorf("versionName=%v, want 1.2.3", m["versionName"])
	}
	if m["builtAt"] != "2026-01-01T00:00:00Z" {
		t.Errorf("builtAt=%v", m["builtAt"])
	}
	if m["available"] != true {
		t.Errorf("available=%v, want true", m["available"])
	}
}

// TestAPKVersionCoerceWrongTypes exercises the strict coercion: versionCode is
// int-or-0, versionName/builtAt fall back to the default when not a string.
func TestAPKVersionCoerceWrongTypes(t *testing.T) {
	dir := t.TempDir()
	apkPath := filepath.Join(dir, "app-release.apk")
	os.WriteFile(apkPath, []byte("x"), 0o644)
	os.WriteFile(filepath.Join(dir, "version.json"),
		[]byte(`{"versionCode":"NaN","versionName":99,"builtAt":true}`), 0o644)
	t.Setenv("GHOSTTY_RELAY_APK_PATH", apkPath)

	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/app/version", nil, nil)
	var m map[string]any
	resp.decode(t, &m)
	if v, _ := m["versionCode"].(float64); int(v) != 0 {
		t.Errorf("versionCode=%v, want 0 (string coerces to 0)", m["versionCode"])
	}
	if m["versionName"] != "unknown" {
		t.Errorf("versionName=%v, want unknown (non-string -> default)", m["versionName"])
	}
	if m["builtAt"] != "" {
		t.Errorf("builtAt=%v, want empty (non-string -> default)", m["builtAt"])
	}
	if m["available"] != true {
		t.Errorf("available=%v, want true", m["available"])
	}
}

// ---- web manifest parsing + lenient (str()) coercion ----

func TestWebManifestParsed(t *testing.T) {
	cfg := newTestConfig(t)
	os.WriteFile(filepath.Join(cfg.StaticRoot, "manifest.json"),
		[]byte(`{"webVersion":"9.9.9","sha256":"deadbeef","sizeBytes":2048,"builtAt":"t","bundleUrl":"/api/web/bundle","requiredApkVersionCode":7}`), 0o644)
	ts, _ := newTestServer(t, cfg)

	resp := doReq(t, http.MethodGet, ts.URL+"/api/web/manifest.json", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	var m map[string]any
	resp.decode(t, &m)
	if m["webVersion"] != "9.9.9" {
		t.Errorf("webVersion=%v", m["webVersion"])
	}
	if m["sha256"] != "deadbeef" {
		t.Errorf("sha256=%v", m["sha256"])
	}
	if v, _ := m["sizeBytes"].(float64); int(v) != 2048 {
		t.Errorf("sizeBytes=%v, want 2048", m["sizeBytes"])
	}
	if m["bundleUrl"] != "/api/web/bundle" {
		t.Errorf("bundleUrl=%v", m["bundleUrl"])
	}
	if v, _ := m["requiredApkVersionCode"].(float64); int(v) != 7 {
		t.Errorf("requiredApkVersionCode=%v, want 7", m["requiredApkVersionCode"])
	}
	if m["available"] != true {
		t.Errorf("available=%v, want true", m["available"])
	}
}

// TestWebManifestLenientCoerce verifies the lenient str() coercion path:
// a non-string webVersion is stringified (unlike apk_version's strict default).
func TestWebManifestLenientCoerce(t *testing.T) {
	cfg := newTestConfig(t)
	os.WriteFile(filepath.Join(cfg.StaticRoot, "manifest.json"),
		[]byte(`{"webVersion":123}`), 0o644)
	ts, _ := newTestServer(t, cfg)

	resp := doReq(t, http.MethodGet, ts.URL+"/api/web/manifest.json", nil, nil)
	var m map[string]any
	resp.decode(t, &m)
	if m["webVersion"] != "123" {
		t.Errorf("webVersion=%v, want \"123\" (lenient str() coercion)", m["webVersion"])
	}
}

// ---- successful downloads (apk + web bundle) ----

func TestAPKDownloadSuccess(t *testing.T) {
	dir := t.TempDir()
	apkPath := filepath.Join(dir, "app-release.apk")
	apkContent := []byte("PK\x03\x04 fake apk payload")
	os.WriteFile(apkPath, apkContent, 0o644)
	t.Setenv("GHOSTTY_RELAY_APK_PATH", apkPath)

	ts, st := newTestServer(t, newTestConfig(t))
	gr := doReq(t, http.MethodPost, ts.URL+"/api/app/android/grant", nil, bearer("user-tok"))
	var gm map[string]any
	gr.decode(t, &gm)
	grant, _ := gm["token"].(string)

	resp := doReq(t, http.MethodGet, ts.URL+"/api/app/android?dl="+grant, nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if ct := resp.headers.Get("Content-Type"); ct != "application/vnd.android.package-archive" {
		t.Errorf("content-type=%q", ct)
	}
	if !strings.Contains(resp.headers.Get("Content-Disposition"), apkDownloadFilename) {
		t.Errorf("content-disposition=%q", resp.headers.Get("Content-Disposition"))
	}
	if !strings.HasPrefix(string(resp.body), "PK") || len(resp.body) != len(apkContent) {
		t.Errorf("body len=%d, want %d", len(resp.body), len(apkContent))
	}
	if got := metricValue(st, "apk_download_total"); got != 1 {
		t.Errorf("apk_download_total=%d", got)
	}
}

func TestAPKDownloadSuccessBearer(t *testing.T) {
	dir := t.TempDir()
	apkPath := filepath.Join(dir, "app-release.apk")
	os.WriteFile(apkPath, []byte("apkbytes"), 0o644)
	t.Setenv("GHOSTTY_RELAY_APK_PATH", apkPath)

	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/app/android", nil, bearer("user-tok"))
	if resp.status != 200 {
		t.Fatalf("bearer download status=%d body=%s", resp.status, resp.body)
	}
}

func TestWebBundleSuccess(t *testing.T) {
	dir := t.TempDir()
	bundlePath := filepath.Join(dir, "dist.zip")
	zip := []byte("PK\x03\x04 fake zip bundle")
	os.WriteFile(bundlePath, zip, 0o644)
	t.Setenv("GHOSTTY_RELAY_WEB_BUNDLE_PATH", bundlePath)

	ts, st := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/web/bundle", nil, bearer("user-tok"))
	if resp.status != 200 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if resp.headers.Get("Content-Type") != "application/zip" {
		t.Errorf("content-type=%q", resp.headers.Get("Content-Type"))
	}
	if len(resp.body) != len(zip) {
		t.Errorf("body len=%d, want %d", len(resp.body), len(zip))
	}
	if got := metricValue(st, "web_bundle_total"); got != 1 {
		t.Errorf("web_bundle_total=%d", got)
	}
}

// ---- min apk version code parsing ----

func TestMinAPKVersionCode(t *testing.T) {
	t.Setenv("GHOSTTY_RELAY_MIN_APK_VERSION_CODE", "-5")
	if got := minAPKVersionCode(); got != 0 {
		t.Errorf("negative -> %d, want 0 (clamped)", got)
	}
	t.Setenv("GHOSTTY_RELAY_MIN_APK_VERSION_CODE", "not-a-number")
	if got := minAPKVersionCode(); got != 0 {
		t.Errorf("invalid -> %d, want 0", got)
	}
	t.Setenv("GHOSTTY_RELAY_MIN_APK_VERSION_CODE", "37")
	if got := minAPKVersionCode(); got != 37 {
		t.Errorf("valid -> %d, want 37", got)
	}
}

// ---- apk grant expiry deletion branch ----

func TestAPKDownloadExpiredGrantDeleted(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	st.mu.Lock()
	st.apkGrants["stale"] = nowSec() - 1 // already expired
	st.mu.Unlock()

	resp := doReq(t, http.MethodGet, ts.URL+"/api/app/android?dl=stale", nil, nil)
	if resp.status != 401 {
		t.Fatalf("status=%d, want 401", resp.status)
	}
	if e := resp.errorField(t); e != "invalid or expired grant" {
		t.Errorf("error=%q", e)
	}
	st.mu.Lock()
	_, present := st.apkGrants["stale"]
	st.mu.Unlock()
	if present {
		t.Errorf("expired grant was not deleted on access")
	}
}
