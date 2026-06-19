package com.ghostty.sessionsharing;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Base64;

import androidx.core.content.FileProvider;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

/**
 * App 内安装 APK 更新。
 *
 * <p><b>为什么下载不在插件里做</b>:本项目目标设备(HarmonyOS / ICL-AL20
 * WebView)在 <b>自签证书 NSC</b> 场景下,插件内 {@code HttpURLConnection}
 * 的 TLS 握手会无限 hang —— NSC pin 只对 WebView 侧一致生效(见
 * {@code src/web-update.js} 的实测注释)。所以下载交给 JS 端 {@code fetch}
 * (WebView 网络栈,自签证书已验证可用),APK 字节分块 base64 喂进来落盘到
 * {@code cacheDir},本插件只负责「落盘 + 拉起系统安装器」。chunk 机制与
 * {@link WebUpdatePlugin} 相同:绕过 HarmonyOS WebMessageListener ~64KB 的
 * 单消息上限。
 *
 * <p><b>安装包清理时机</b>:系统安装器异步读取 APK,拉起安装后<b>不能</b>立刻
 * 删除文件,否则安装会失败。改为「下次启动 app 时」({@link #load()})清理上次
 * 遗留的安装包 —— 此时绝无安装在进行,删除安全;每次开始新下载前
 * ({@link #installBegin}) 也会先删一次旧包。
 *
 * <p>暴露给 JS({@code registerPlugin("ApkInstaller")})的方法:
 * <ul>
 *   <li>{@code ensureInstallPermission()} — Android 8+ 检查「安装未知应用」
 *       权限,缺失则跳系统设置页并 {@code reject("NEED_INSTALL_PERMISSION")}</li>
 *   <li>{@code installBegin()} — 在 cacheDir 新建安装包文件</li>
 *   <li>{@code installChunk({chunk})} — base64 解码后追加写入</li>
 *   <li>{@code installFinalize()} — 关闭文件 + FileProvider 拉起系统安装器</li>
 *   <li>{@code installAbort()} — 放弃并删除半成品</li>
 * </ul>
 */
@CapacitorPlugin(name = "ApkInstaller")
public class ApkInstallerPlugin extends Plugin {

    private static final String APK_NAME = "ghostty-sharing-update.apk";

    // 单次安装的落盘流。一次 app 运行只支持一个进行中的安装,synchronized(this) 保护。
    private OutputStream stageStream;

    @Override
    public void load() {
        // 安装器异步读取 APK,拉起安装后不能立刻删,否则安装失败。这里在「下次
        // 启动 app」时清理上次遗留的安装包 —— 此时绝无安装在进行,删除安全。
        deleteApkQuietly();
    }

    @PluginMethod
    public void ensureInstallPermission(PluginCall call) {
        // 先查权限,避免白下载十几 MB 才发现不能安装。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && !getContext().getPackageManager().canRequestPackageInstalls()) {
            openInstallPermissionSettings();
            call.reject("NEED_INSTALL_PERMISSION");
            return;
        }
        call.resolve();
    }

    @PluginMethod
    public void installBegin(PluginCall call) {
        new Thread(() -> {
            try {
                synchronized (this) {
                    closeStageQuietly();
                    // 覆盖前先删掉上次遗留的安装包。
                    deleteApkQuietly();
                    stageStream = new FileOutputStream(apkFile());
                }
                call.resolve();
            } catch (Exception e) {
                String msg = e.getMessage();
                call.reject(msg == null ? "install_begin_failed" : msg, e);
            }
        }, "ApkInstaller-Begin").start();
    }

    @PluginMethod
    public void installChunk(PluginCall call) {
        final String chunk = call.getString("chunk");
        if (chunk == null) {
            call.reject("chunk required");
            return;
        }
        new Thread(() -> {
            try {
                byte[] bytes = Base64.decode(chunk, Base64.DEFAULT);
                if (bytes == null) {
                    throw new IOException("base64 decode returned null");
                }
                synchronized (this) {
                    if (stageStream == null) {
                        throw new IOException("install not begun");
                    }
                    stageStream.write(bytes);
                }
                JSObject ret = new JSObject();
                ret.put("written", bytes.length);
                call.resolve(ret);
            } catch (Exception e) {
                String msg = e.getMessage();
                call.reject(msg == null ? "install_chunk_failed" : msg, e);
            }
        }, "ApkInstaller-Chunk").start();
    }

    @PluginMethod
    public void installFinalize(PluginCall call) {
        new Thread(() -> {
            File apk;
            try {
                synchronized (this) {
                    if (stageStream == null) {
                        throw new IOException("install not begun");
                    }
                    stageStream.flush();
                    stageStream.close();
                    stageStream = null;
                }
                apk = apkFile();
                if (!apk.exists() || apk.length() == 0) {
                    throw new IOException("downloaded apk missing or empty");
                }
            } catch (Exception e) {
                String msg = e.getMessage();
                call.reject(msg == null ? "install_finalize_failed" : msg, e);
                return;
            }
            installApk(apk, call);
        }, "ApkInstaller-Finalize").start();
    }

    @PluginMethod
    public void installAbort(PluginCall call) {
        synchronized (this) {
            closeStageQuietly();
            deleteApkQuietly();
        }
        call.resolve();
    }

    private void installApk(File apk, PluginCall call) {
        getActivity().runOnUiThread(() -> {
            try {
                // FileProvider 生成 content:// URI(而非 file://,避免 Android 7+
                // 的 FileUriExposedException),authority 与 AndroidManifest 的
                // ${applicationId}.fileprovider 一致。
                Uri uri = FileProvider.getUriForFile(
                        getContext(),
                        getContext().getPackageName() + ".fileprovider",
                        apk);
                Intent intent = new Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                getActivity().startActivity(intent);
                call.resolve();
            } catch (Exception e) {
                call.reject("拉起安装器失败：" + e.getMessage(), e);
            }
        });
    }

    private void openInstallPermissionSettings() {
        getActivity().runOnUiThread(() -> {
            Intent intent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:" + getContext().getPackageName()))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getActivity().startActivity(intent);
        });
    }

    private File apkFile() {
        return new File(getContext().getCacheDir(), APK_NAME);
    }

    private synchronized void closeStageQuietly() {
        if (stageStream != null) {
            try {
                stageStream.close();
            } catch (IOException ignored) {
                // best effort
            }
            stageStream = null;
        }
    }

    private void deleteApkQuietly() {
        try {
            File apk = apkFile();
            if (apk.exists()) {
                //noinspection ResultOfMethodCallIgnored
                apk.delete();
            }
        } catch (Exception ignored) {
            // 清理失败无所谓,下次下载前 / 下次启动时还会再删。
        }
    }
}
