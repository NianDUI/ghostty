package com.ghostty.sessionsharing;

import android.util.Base64;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Web OTA helper. Verifies + unpacks a zipped dist into
 * {@code filesDir/web/&lt;version&gt;/}. The plugin is intentionally
 * "no network" — JS fetches the bundle via the WebView's HTTP stack
 * (the only one we've verified works on the target HarmonyOS WebView)
 * and hands us the bytes as base64. Routing/persistence stay with
 * Capacitor 8's built-in WebView plugin (setServerBasePath +
 * persistServerBasePath).
 *
 * <p>Atomic update: base64-decode + sha256 verify -&gt; unzip into
 * {@code &lt;version&gt;.partial/_unpack/} -&gt; rename to
 * {@code &lt;version&gt;/}. A {@code .version} marker (version + sha)
 * is written last so partial directories cannot be activated.
 */
@CapacitorPlugin(name = "GhosttyWebUpdate")
public class WebUpdatePlugin extends Plugin {

    private static final String SUBDIR = "web";
    private static final int BUFFER_SIZE = 64 * 1024;

    // Chunked install: passing the full ~290 KB base64 bundle in one
    // installFromBase64 call hangs on HarmonyOS WebView (ICL-AL20).
    // Suspect: Capacitor 8 routes plugin calls through WebMessageListener
    // on Chrome 114+, and the HarmonyOS WebView quietly drops messages
    // beyond ~64 KB. Chunked transfer keeps each call comfortably under
    // that ceiling. State (FileOutputStream + MessageDigest) lives in
    // module-level mutable fields keyed by version — one in-flight
    // install per APP run is the only supported case.
    private final java.util.HashMap<String, java.io.OutputStream> stageStreams = new java.util.HashMap<>();
    private final java.util.HashMap<String, MessageDigest> stageDigests = new java.util.HashMap<>();
    private final java.util.HashMap<String, File> stageDirs = new java.util.HashMap<>();
    private final java.util.HashMap<String, File> stageZips = new java.util.HashMap<>();

    @PluginMethod
    public void installBegin(PluginCall call) {
        final String version = call.getString("version");
        if (version == null) {
            call.reject("version required");
            return;
        }
        if (!isValidVersion(version)) {
            call.reject("invalid version label");
            return;
        }
        new Thread(() -> {
            try {
                synchronized (this) {
                    closeStage(version);
                    File webRoot = new File(getContext().getFilesDir(), SUBDIR);
                    if (!webRoot.exists() && !webRoot.mkdirs()) {
                        throw new IOException("could not create " + webRoot);
                    }
                    File stageDir = new File(webRoot, version + ".partial");
                    deleteRecursive(stageDir);
                    if (!stageDir.mkdirs()) {
                        throw new IOException("could not create stage dir " + stageDir);
                    }
                    File zipFile = new File(stageDir, "bundle.zip");
                    stageDirs.put(version, stageDir);
                    stageZips.put(version, zipFile);
                    stageStreams.put(version, new FileOutputStream(zipFile));
                    stageDigests.put(version, MessageDigest.getInstance("SHA-256"));
                }
                call.resolve();
            } catch (Exception e) {
                String msg = e.getMessage();
                call.reject(msg == null ? "install_begin_failed" : msg, e);
            }
        }, "GhosttyWebUpdate-Begin").start();
    }

    @PluginMethod
    public void installChunk(PluginCall call) {
        final String version = call.getString("version");
        final String chunk = call.getString("chunk");
        if (version == null || chunk == null) {
            call.reject("version and chunk required");
            return;
        }
        new Thread(() -> {
            try {
                byte[] bytes = Base64.decode(chunk, Base64.DEFAULT);
                if (bytes == null) {
                    throw new IOException("base64 decode returned null");
                }
                synchronized (this) {
                    java.io.OutputStream out = stageStreams.get(version);
                    MessageDigest sha = stageDigests.get(version);
                    if (out == null || sha == null) {
                        throw new IOException("install not begun for version " + version);
                    }
                    out.write(bytes);
                    sha.update(bytes);
                }
                JSObject ret = new JSObject();
                ret.put("written", bytes.length);
                call.resolve(ret);
            } catch (Exception e) {
                String msg = e.getMessage();
                call.reject(msg == null ? "install_chunk_failed" : msg, e);
            }
        }, "GhosttyWebUpdate-Chunk").start();
    }

    @PluginMethod
    public void installFinalize(PluginCall call) {
        final String version = call.getString("version");
        final String expectedSha = call.getString("sha256");
        if (version == null || expectedSha == null) {
            call.reject("version and sha256 required");
            return;
        }
        new Thread(() -> {
            try {
                File destDir;
                synchronized (this) {
                    java.io.OutputStream out = stageStreams.remove(version);
                    MessageDigest sha = stageDigests.remove(version);
                    File stageDir = stageDirs.remove(version);
                    File zipFile = stageZips.remove(version);
                    if (out == null || sha == null || stageDir == null || zipFile == null) {
                        throw new IOException("install not begun for version " + version);
                    }
                    try {
                        out.close();
                        String actual = toHex(sha.digest());
                        if (!actual.equalsIgnoreCase(expectedSha)) {
                            throw new IOException(
                                "sha256 mismatch (expected=" + expectedSha + " actual=" + actual + ")");
                        }
                        destDir = promoteFromZip(version, stageDir, zipFile, expectedSha);
                    } finally {
                        deleteRecursive(stageDir);
                    }
                }
                JSObject ret = new JSObject();
                ret.put("path", destDir.getAbsolutePath());
                ret.put("version", version);
                call.resolve(ret);
            } catch (Exception e) {
                String msg = e.getMessage();
                call.reject(msg == null ? "install_finalize_failed" : msg, e);
            }
        }, "GhosttyWebUpdate-Finalize").start();
    }

    @PluginMethod
    public void installAbort(PluginCall call) {
        final String version = call.getString("version");
        if (version == null) {
            call.reject("version required");
            return;
        }
        synchronized (this) {
            closeStage(version);
        }
        call.resolve();
    }

    private synchronized void closeStage(String version) {
        java.io.OutputStream out = stageStreams.remove(version);
        if (out != null) {
            try { out.close(); } catch (IOException ignored) {}
        }
        stageDigests.remove(version);
        File stageDir = stageDirs.remove(version);
        stageZips.remove(version);
        if (stageDir != null) {
            deleteRecursive(stageDir);
        }
    }

    private File promoteFromZip(String version, File stageDir, File zipFile, String expectedSha)
            throws IOException {
        File unpackDir = new File(stageDir, "_unpack");
        if (!unpackDir.mkdirs()) {
            throw new IOException("could not create unpack dir");
        }
        unzipSafely(zipFile, unpackDir);
        zipFile.delete();
        File webRoot = new File(getContext().getFilesDir(), SUBDIR);
        File destDir = new File(webRoot, version);
        deleteRecursive(destDir);
        if (!unpackDir.renameTo(destDir)) {
            throw new IOException("could not promote stage to dest " + destDir);
        }
        try (FileOutputStream fos = new FileOutputStream(new File(destDir, ".version"))) {
            fos.write((version + "\n" + expectedSha + "\n").getBytes(StandardCharsets.UTF_8));
        }
        return destDir;
    }

    /**
     * One-shot activate: persist the basePath, swap Capacitor's server,
     * and reload the WebView in a single plugin call.
     *
     * <p>Why one shot: doing this as three separate JS-to-plugin calls
     * (setServerBasePath / persistServerBasePath / reload) hangs on
     * HarmonyOS WebView (ICL-AL20). The first call's
     * {@code webView.post(loadUrl)} occupies the UI thread, which then
     * cannot deliver the plugin response back to JS, leaving the JS
     * await on call #1 unresolved forever. Folding everything into a
     * single UI-thread Runnable resolves the call before any
     * UI-blocking work begins, so JS isn't waiting on a thread that's
     * about to navigate away anyway.
     *
     * <p>Pass {@code path=""} to revert to the APK-bundled assets
     * (matches Capacitor's own "empty path = host assets" semantics).
     */
    @PluginMethod
    public void activate(PluginCall call) {
        final String path = call.getString("path", "");
        // Resolve before any UI work — the WebView is about to navigate,
        // and on HarmonyOS the message-listener reply path needs the UI
        // thread free to flush; queuing the reload first deadlocks it.
        call.resolve();
        // Persist outside UI thread (SharedPreferences.apply is async).
        android.content.SharedPreferences prefs = getContext().getSharedPreferences(
            com.getcapacitor.plugin.WebView.WEBVIEW_PREFS_NAME,
            android.content.Context.MODE_PRIVATE);
        prefs.edit()
            .putString(com.getcapacitor.plugin.WebView.CAP_SERVER_PATH, path)
            .apply();
        final android.webkit.WebView wv = bridge.getWebView();
        final String url = bridge.getLocalUrl();
        wv.post(() -> {
            if (path.isEmpty()) {
                // Empty path = revert to APK-bundled assets. We must
                // use setServerAssetPath (not setServerBasePath(""))
                // because the latter calls localServer.hostFiles("")
                // which leaves the local server with no served path,
                // and the WebView ends up with ERR_CONNECTION_REFUSED.
                // "public" is Capacitor's default asset directory
                // (capacitor.config webDir → assets/public/ at build).
                bridge.setServerAssetPath("public");
            } else {
                // setServerBasePath() updates localServer routing AND
                // posts a loadUrl of its own. Our stopLoading +
                // cache-buster loadUrl below overrides the queued
                // one — the cache-buster query also avoids HarmonyOS
                // WebView's "already navigating to same URL, drop"
                // dedupe that was swallowing reloads previously.
                bridge.setServerBasePath(path);
            }
            wv.stopLoading();
            wv.loadUrl(url + "?ota=" + System.currentTimeMillis());
        });
    }

    @PluginMethod
    public void clearCache(PluginCall call) {
        String keep = call.getString("keepVersion", "");
        File webRoot = new File(getContext().getFilesDir(), SUBDIR);
        int removed = 0;
        if (webRoot.exists()) {
            File[] children = webRoot.listFiles();
            if (children != null) {
                for (File child : children) {
                    if (!child.getName().equals(keep)) {
                        if (deleteRecursive(child)) {
                            removed++;
                        }
                    }
                }
            }
        }
        JSObject ret = new JSObject();
        ret.put("removed", removed);
        call.resolve(ret);
    }

    @PluginMethod
    public void getCurrentBasePath(PluginCall call) {
        String path = bridge.getServerBasePath();
        JSObject ret = new JSObject();
        ret.put("path", path == null ? "" : path);
        call.resolve(ret);
    }

    @PluginMethod
    public void getLocalWebVersion(PluginCall call) {
        // Marker format is two lines: version label on line 1, sha256
        // on line 2. Older single-line markers (version only) still
        // parse — sha just comes back empty, which is correctly handled
        // by the JS-side hasUpdate logic (empty local sha + any server
        // sha = treat as outdated, prompt re-install).
        String basePath = bridge.getServerBasePath();
        String version = "";
        String sha = "";
        if (basePath != null && !basePath.isEmpty()) {
            File marker = new File(basePath, ".version");
            if (marker.exists() && marker.isFile()) {
                try (FileInputStream fis = new FileInputStream(marker)) {
                    byte[] buf = new byte[512];
                    int n = fis.read(buf);
                    if (n > 0) {
                        String body = new String(buf, 0, n, StandardCharsets.UTF_8);
                        String[] lines = body.split("\\R", -1);
                        if (lines.length >= 1) version = lines[0].trim();
                        if (lines.length >= 2) sha = lines[1].trim();
                    }
                } catch (IOException ignored) {
                    // Marker unreadable — treat as unknown, fall through.
                }
            }
        }
        JSObject ret = new JSObject();
        ret.put("version", version);
        ret.put("sha256", sha);
        ret.put("path", basePath == null ? "" : basePath);
        call.resolve(ret);
    }

    private void unzipSafely(File zipFile, File unpackDir) throws IOException {
        String canonicalRoot = unpackDir.getCanonicalPath();
        try (FileInputStream fis = new FileInputStream(zipFile);
             ZipInputStream zis = new ZipInputStream(fis)) {
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                String name = entry.getName();
                if (name.startsWith("/") || name.contains("..")) {
                    throw new IOException("unsafe zip entry: " + name);
                }
                File outFile = new File(unpackDir, name);
                String canonical = outFile.getCanonicalPath();
                if (!canonical.equals(canonicalRoot)
                        && !canonical.startsWith(canonicalRoot + File.separator)) {
                    throw new IOException("zip entry escapes root: " + name);
                }
                if (entry.isDirectory()) {
                    outFile.mkdirs();
                    zis.closeEntry();
                    continue;
                }
                File parent = outFile.getParentFile();
                if (parent != null && !parent.exists() && !parent.mkdirs()) {
                    throw new IOException("mkdir failed: " + parent);
                }
                try (FileOutputStream fos = new FileOutputStream(outFile)) {
                    byte[] buf = new byte[BUFFER_SIZE];
                    int n;
                    while ((n = zis.read(buf)) > 0) {
                        fos.write(buf, 0, n);
                    }
                }
                zis.closeEntry();
            }
        }
    }

    private boolean deleteRecursive(File f) {
        if (!f.exists()) return true;
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File c : children) {
                    deleteRecursive(c);
                }
            }
        }
        return f.delete();
    }

    private static boolean isValidVersion(String v) {
        if (v.isEmpty() || v.length() > 64) return false;
        for (int i = 0; i < v.length(); i++) {
            char c = v.charAt(i);
            boolean ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
            if (!ok) return false;
        }
        return true;
    }

    private static String toHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }
}
