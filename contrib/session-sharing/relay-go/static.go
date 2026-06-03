package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

var staticContentTypes = map[string]string{
	".html": "text/html; charset=utf-8",
	".js":   "application/javascript; charset=utf-8",
	".css":  "text/css; charset=utf-8",
	".json": "application/json; charset=utf-8",
	".wasm": "application/wasm",
}

// resolveWasmPath mirrors the /ghostty-vt.wasm special case. server.py uses
// __file__.parents[3]/zig-out/bin; a compiled binary has no source path, so
// we honour GHOSTTY_RELAY_WASM_PATH or derive the repo root from staticRoot
// (contrib/session-sharing/web -> repo root is three levels up).
func resolveWasmPath(staticRoot string) string {
	if override := strings.TrimSpace(os.Getenv("GHOSTTY_RELAY_WASM_PATH")); override != "" {
		return override
	}
	repoGuess := filepath.Join(staticRoot, "..", "..", "..")
	return filepath.Join(repoGuess, "zig-out", "bin", "ghostty-vt.wasm")
}

// resolveStaticPath mirrors resolve_static_path, including the path-traversal
// guard. Returns ("", false) when nothing should be served.
func resolveStaticPath(staticRoot, target string) (string, bool) {
	if target == "/ghostty-vt.wasm" {
		wasm := resolveWasmPath(staticRoot)
		if fileExists(wasm) {
			return wasm, true
		}
	}

	path := target
	if path == "/" {
		path = "/index.html"
	}
	rel := strings.TrimPrefix(path, "/")
	resolved := filepath.Clean(filepath.Join(staticRoot, rel))

	rootClean := filepath.Clean(staticRoot)
	// resolved must live strictly under static_root.
	if !strings.HasPrefix(resolved, rootClean+string(filepath.Separator)) {
		return "", false
	}
	if !fileExists(resolved) {
		return "", false
	}
	return resolved, true
}

func (s *server) serveStatic(w http.ResponseWriter, r *http.Request, path string) {
	resolved, ok := resolveStaticPath(s.config.StaticRoot, path)
	if !ok {
		writeResponse(w, r, 404, []byte("not found"), "text/plain; charset=utf-8", nil)
		return
	}
	contentType, found := staticContentTypes[strings.ToLower(filepath.Ext(resolved))]
	if !found {
		contentType = "application/octet-stream"
	}
	body, err := os.ReadFile(resolved)
	if err != nil {
		writeResponse(w, r, 404, []byte("not found"), "text/plain; charset=utf-8", nil)
		return
	}
	writeResponse(w, r, 200, body, contentType, nil)
}
