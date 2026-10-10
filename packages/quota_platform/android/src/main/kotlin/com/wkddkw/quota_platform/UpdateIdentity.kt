package com.wkddkw.quota_platform

import java.net.URI

data class UpdateIdentity(val packageName: String, val code: Long, val version: String, val signers: Set<String>)

object UpdatePolicy {
    fun installedOrOlder(target: String, installed: String): Boolean {
        fun parts(value: String): List<Long>? {
            if (!Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(value)) return null
            return value.split('.').map { it.toLongOrNull() ?: return null }
        }
        val desired = parts(target) ?: return false
        val current = parts(installed) ?: return false
        for (i in 0..2) { if (desired[i] != current[i]) return desired[i] < current[i] }
        return true
    }

    fun validUrl(url: String, version: String): Boolean {
        if (!Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(version)) return false
        return try {
            val uri = URI(url)
            uri.scheme == "https" && uri.host == "github.com" && uri.port == -1 && uri.userInfo == null && uri.query == null && uri.fragment == null &&
                uri.rawPath == "/wkddkw/cliproxy-quota/releases/download/v$version/cliproxy-quota-v$version.apk"
        } catch (_: Exception) { false }
    }
    fun error(candidate: UpdateIdentity, installed: UpdateIdentity, expectedVersion: String): String? = when {
        candidate.packageName != installed.packageName -> "下载包不是本应用"
        candidate.code <= installed.code -> "下载包不是更新版本，请重新检查更新"
        candidate.version != expectedVersion -> "下载包版本与更新信息不符"
        candidate.signers.isEmpty() || candidate.signers != installed.signers -> "下载包签名不匹配，无法覆盖安装"
        else -> null
    }
}
