package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ---- 7. APK grant / download / version / web bundle & manifest ----

func TestAPKGrant(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodPost, ts.URL+"/api/app/android/grant", nil, bearer("user-tok"))
	if resp.status != 200 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	var m map[string]any
	resp.decode(t, &m)
	if m["token"] == nil || m["token"] == "" {
		t.Errorf("missing grant token: %s", resp.body)
	}
	if v, _ := m["expires_in"].(float64); int(v) != 60 {
		t.Errorf("expires_in=%v, want 60", m["expires_in"])
	}
	if got := metricValue(st, "apk_download_grant_total"); got != 1 {
		t.Errorf("apk_download_grant_total=%d", got)
	}
}

func TestAPKGrantMissingBearer(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodPost, ts.URL+"/api/app/android/grant", nil, nil)
	if resp.status != 401 {
		t.Fatalf("status=%d", resp.status)
	}
}

func TestAPKDownloadGrantFlow(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	// Acquire a grant.
	gr := doReq(t, http.MethodPost, ts.URL+"/api/app/android/grant", nil, bearer("user-tok"))
	var gm map[string]any
	gr.decode(t, &gm)
	grant, _ := gm["token"].(string)

	// File is missing -> 503 apk_not_available (valid grant passes auth).
	resp := doReq(t, http.MethodGet, ts.URL+"/api/app/android?dl="+grant, nil, nil)
	if resp.status != 503 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "apk_not_available" {
		t.Errorf("error=%q", e)
	}

	// Invalid grant -> 401.
	bad := doReq(t, http.MethodGet, ts.URL+"/api/app/android?dl=nope", nil, nil)
	if bad.status != 401 {
		t.Fatalf("invalid grant status=%d", bad.status)
	}
	if got := metricValue(st, "apk_download_rejected_total"); got < 1 {
		t.Errorf("apk_download_rejected_total=%d", got)
	}
}

func TestAPKVersionMissing(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/app/version", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d", resp.status)
	}
	var m map[string]any
	resp.decode(t, &m)
	if m["available"] != false {
		t.Errorf("available=%v, want false", m["available"])
	}
}

func TestWebManifestMissing(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/web/manifest.json", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d", resp.status)
	}
	var m map[string]any
	resp.decode(t, &m)
	if m["available"] != false {
		t.Errorf("available=%v, want false", m["available"])
	}
}

func TestWebBundleMissing(t *testing.T) {
	ts, st := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/web/bundle", nil, bearer("user-tok"))
	if resp.status != 503 {
		t.Fatalf("status=%d body=%s", resp.status, resp.body)
	}
	if e := resp.errorField(t); e != "bundle_not_available" {
		t.Errorf("error=%q", e)
	}
	// web_bundle_rejected_total is a dynamic metric, must surface in /metrics.
	mt := doReq(t, http.MethodGet, ts.URL+"/metrics", nil, nil)
	if !strings.Contains(string(mt.body), "ghostty_relay_web_bundle_rejected_total ") {
		t.Errorf("web_bundle_rejected_total absent from /metrics:\n%s", mt.body)
	}
	if got := metricValue(st, "web_bundle_rejected_total"); got < 1 {
		t.Errorf("web_bundle_rejected_total=%d", got)
	}
}

func TestWebBundleMissingBearer(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/api/web/bundle", nil, nil)
	if resp.status != 401 {
		t.Fatalf("status=%d", resp.status)
	}
}

// ---- 8. static file serving ----

func TestStaticServesIndex(t *testing.T) {
	cfg := newTestConfig(t)
	indexPath := filepath.Join(cfg.StaticRoot, "index.html")
	if err := os.WriteFile(indexPath, []byte("<html>hi</html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	ts, _ := newTestServer(t, cfg)
	resp := doReq(t, http.MethodGet, ts.URL+"/", nil, nil)
	if resp.status != 200 {
		t.Fatalf("status=%d", resp.status)
	}
	if !strings.HasPrefix(resp.headers.Get("Content-Type"), "text/html") {
		t.Errorf("content-type=%q", resp.headers.Get("Content-Type"))
	}
	if string(resp.body) != "<html>hi</html>" {
		t.Errorf("body=%q", resp.body)
	}
}

func TestStaticTraversalBlocked(t *testing.T) {
	cfg := newTestConfig(t)
	// Plant a secret outside StaticRoot to make sure traversal can't reach it.
	parent := filepath.Dir(cfg.StaticRoot)
	_ = os.WriteFile(filepath.Join(parent, "secret.txt"), []byte("nope"), 0o644)
	ts, _ := newTestServer(t, cfg)

	// Use raw (unescaped) target so net/http's URL parsing doesn't normalize.
	resp := doReq(t, http.MethodGet, ts.URL+"/../secret.txt", nil, nil)
	if resp.status != 404 {
		t.Fatalf("traversal status=%d body=%s", resp.status, resp.body)
	}
}

func TestStaticNotFound(t *testing.T) {
	ts, _ := newTestServer(t, newTestConfig(t))
	resp := doReq(t, http.MethodGet, ts.URL+"/does-not-exist.js", nil, nil)
	if resp.status != 404 {
		t.Fatalf("status=%d", resp.status)
	}
}
