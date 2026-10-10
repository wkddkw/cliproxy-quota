package com.wkddkw.quota_platform

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest

/** GitHub downloads are separate from the user's CLIProxy connection and keys. */
class AppUpdates(private val context: Context) {
    private val prefs = context.getSharedPreferences("app_update", Context.MODE_PRIVATE)
    private val downloads = context.getSystemService(DownloadManager::class.java)
    private val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    private fun installed() = context.packageManager.getPackageInfo(context.packageName, flags)
    private fun identity(info: PackageInfo): UpdateIdentity {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return UpdateIdentity(info.packageName, if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong(), info.versionName.orEmpty(), signatures?.map { sha(it.toByteArray()) }?.toSet() ?: emptySet())
    }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun file(name: String = prefs.getString("fileName", "update.apk").orEmpty()): File {
        require(Regex("update(?:-[0-9.]+-[0-9]+)?\\.apk").matches(name)) { "下载文件记录无效，请清理下载包" }
        return File(context.getExternalFilesDir(null) ?: throw IllegalStateException("下载存储不可用"), "updates/$name")
    }
    fun version(): Map<String, Any> = identity(installed()).let { mapOf("version" to it.version, "code" to it.code) }
    fun start(args: Map<*, *>): Long {
        val url = args["url"] as String
        val version = args["version"] as String
        val digest = args["digest"] as? String ?: ""
        require(UpdatePolicy.validUrl(url, version)) { "更新下载地址无效" }
        require(digest.isEmpty() || Regex("sha256:[0-9a-fA-F]{64}").matches(digest)) { "更新校验信息无效" }
        val existing = status()
        if (existing["state"] in listOf("running", "paused")) return prefs.getLong("id", -1)
        cancel()
        val fileName = "update-$version-${System.currentTimeMillis()}.apk"
        val apk = file(fileName)
        require(apk.parentFile!!.mkdirs() || apk.parentFile!!.isDirectory) { "无法创建下载目录" }
        val request = DownloadManager.Request(Uri.parse(url)).setTitle("CLIProxy 更新 v$version")
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setDestinationUri(Uri.fromFile(apk))
        val id = downloads.enqueue(request)
        prefs.edit().putLong("id", id).putString("version", version).putString("digest", digest).putString("fileName", fileName).remove("validationError").commit()
        return id
    }
    fun cancel() {
        val id = prefs.getLong("id", -1)
        if (id >= 0) downloads.remove(id)
        val apk = file()
        if (apk.exists()) require(apk.delete()) { "无法清理旧下载" }
        prefs.edit().clear().commit()
    }
    private fun verify(): File {
        val apk = file()
        require(apk.isFile) { "更新包已丢失，请重新下载" }
        val archive = context.packageManager.getPackageArchiveInfo(apk.absolutePath, flags) ?: throw IllegalStateException("更新包无法识别，请重新下载")
        val error = UpdatePolicy.error(identity(archive), identity(installed()), prefs.getString("version", "").orEmpty())
        require(error == null) { error.orEmpty() }
        val expected = prefs.getString("digest", "").orEmpty()
        if (expected.isNotEmpty()) {
            val digest = MessageDigest.getInstance("SHA-256")
            apk.inputStream().use { input ->
                val buffer = ByteArray(65536)
                while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(actual.equals(expected.removePrefix("sha256:"), ignoreCase = true)) { "下载包校验失败，请重新下载" }
        }
        return apk
    }
    fun status(): Map<String, Any> {
        val id = prefs.getLong("id", -1)
        if (id < 0) return mapOf("state" to "idle")
        val version = prefs.getString("version", "").orEmpty()
        if (UpdatePolicy.installedOrOlder(version, installed().versionName.orEmpty())) { cancel(); return mapOf("state" to "idle") }
        val result = mutableMapOf<String, Any>("version" to version, "canInstall" to (Build.VERSION.SDK_INT < 26 || context.packageManager.canRequestPackageInstalls()))
        val validationError = prefs.getString("validationError", null)
        if (validationError != null) return result + mapOf("state" to "failed", "error" to validationError)
        downloads.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
            if (cursor == null || !cursor.moveToFirst()) return result + mapOf("state" to "failed", "error" to "下载任务已移除，请重试")
            val state = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val done = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            result["progress"] = if (total > 0) (done.toDouble() / total).coerceIn(0.0, 1.0) else -1.0
            result["state"] = when (state) {
                DownloadManager.STATUS_SUCCESSFUL -> "ready"
                DownloadManager.STATUS_FAILED -> "failed"
                DownloadManager.STATUS_PAUSED -> "paused"
                else -> "running"
            }
            if (state == DownloadManager.STATUS_FAILED) result["error"] = "下载失败，请检查网络或存储空间后重试"
        }
        return result
    }
    fun installIntent(): Pair<String, Intent> {
        require(status()["state"] == "ready") { "更新包尚未下载完成，请重新下载或等待" }
        val apk = try { verify() } catch (error: Exception) {
            prefs.edit().putString("validationError", error.message ?: "更新包校验失败，请清理后重新下载").commit()
            throw error
        }
        if (Build.VERSION.SDK_INT >= 26 && !context.packageManager.canRequestPackageInstalls()) {
            return "permission" to Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", apk)
        return "installer" to Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}
