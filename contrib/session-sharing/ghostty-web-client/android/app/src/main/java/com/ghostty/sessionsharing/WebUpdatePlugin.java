package com.ghostty.sessionsharing;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Web OTA helper. Downloads, verifies, and unpacks a zipped dist into
 * {@code filesDir/web/&lt;version&gt;/}. Routing/persistence is handled by
 * Capacitor's built-in WebView plugin via {@code Bridge.setServerBasePath}
 * + {@code persistServerBasePath} from the JS side — we deliberately do
 * not duplicate that logic here.
 *
 * <p>Atomic update: download -&gt; sha256 verify -&gt; unzip into
 * {@code &lt;version&gt;.partial/_unpack/} -&gt; rename to
 * {@code &lt;version&gt;/}. A {@code .version} marker is written last so
 * partial directories cannot be activated.
 */
@CapacitorPlugin(name = "GhosttyWebUpdate")
public class WebUpdatePlugin extends Plugin {

    private static final String SUBDIR = "web";
    private static final int CONNECT_TIMEOUT_MS = 30_000;
    private static final int READ_TIMEOUT_MS = 60_000;
    private static final int BUFFER_SIZE = 64 * 1024;

    @PluginMethod
    public void download(PluginCall call) {
        final String url = call.getString("url");
        final String expectedSha = call.getString("sha256");
        final String version = call.getString("version");
        final String token = call.getString("token");
        if (url == null || expectedSha == null || version == null) {
            call.reject("url, sha256, version are required");
            return;
        }
        if (!isValidVersion(version)) {
            call.reject("invalid version label");
            return;
        }
        new Thread(() -> {
            try {
                File destDir = doDownload(url, expectedSha, version, token);
                JSObject ret = new JSObject();
                ret.put("path", destDir.getAbsolutePath());
                ret.put("version", version);
                call.resolve(ret);
            } catch (Exception e) {
                String msg = e.getMessage();
                call.reject(msg == null ? "download_failed" : msg, e);
            }
        }, "GhosttyWebUpdate-Download").start();
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

    private File doDownload(String url, String expectedSha, String version, String token)
            throws IOException, NoSuchAlgorithmException {
        File webRoot = new File(getContext().getFilesDir(), SUBDIR);
        if (!webRoot.exists() && !webRoot.mkdirs()) {
            throw new IOException("could not create " + webRoot);
        }
        File stageDir = new File(webRoot, version + ".partial");
        deleteRecursive(stageDir);
        if (!stageDir.mkdirs()) {
            throw new IOException("could not create stage dir " + stageDir);
        }
        try {
            File zipFile = new File(stageDir, "bundle.zip");
            downloadAndVerify(url, token, expectedSha, zipFile);

            File unpackDir = new File(stageDir, "_unpack");
            if (!unpackDir.mkdirs()) {
                throw new IOException("could not create unpack dir");
            }
            unzipSafely(zipFile, unpackDir);
            // Drop the zip — already exploded on disk.
            zipFile.delete();

            File destDir = new File(webRoot, version);
            deleteRecursive(destDir);
            if (!unpackDir.renameTo(destDir)) {
                throw new IOException("could not promote stage to dest " + destDir);
            }
            // Write the version marker last so getLocalWebVersion treats
            // partially-promoted dirs as invalid (caller can re-download).
            // Two lines: version label, sha256. The sha is the same one
            // we just verified the zip against, so JS-side checkUpdate
            // can detect re-deploys that share a version label (dirty
            // builds, ad-hoc re-pushes) by comparing sha256.
            try (FileOutputStream fos = new FileOutputStream(new File(destDir, ".version"))) {
                fos.write((version + "\n" + expectedSha + "\n").getBytes(StandardCharsets.UTF_8));
            }
            return destDir;
        } finally {
            deleteRecursive(stageDir);
        }
    }

    private void downloadAndVerify(String url, String token, String expectedSha, File dest)
            throws IOException, NoSuchAlgorithmException {
        URL u = new URL(url);
        HttpURLConnection conn = (HttpURLConnection) u.openConnection();
        try {
            conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
            conn.setReadTimeout(READ_TIMEOUT_MS);
            conn.setRequestMethod("GET");
            if (token != null && !token.isEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + token);
            }
            int code = conn.getResponseCode();
            if (code != 200) {
                throw new IOException("HTTP " + code);
            }
            MessageDigest sha = MessageDigest.getInstance("SHA-256");
            try (InputStream in = conn.getInputStream();
                 OutputStream out = new FileOutputStream(dest)) {
                byte[] buf = new byte[BUFFER_SIZE];
                int n;
                while ((n = in.read(buf)) > 0) {
                    sha.update(buf, 0, n);
                    out.write(buf, 0, n);
                }
            }
            String actual = toHex(sha.digest());
            if (!actual.equalsIgnoreCase(expectedSha)) {
                throw new IOException("sha256 mismatch (expected=" + expectedSha + " actual=" + actual + ")");
            }
        } finally {
            conn.disconnect();
        }
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
