package io.github.clubanderson.clubtivi

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import java.security.MessageDigest

/** APKs stay in app-private cache and must be signed by the installed publisher. */
class BobTvPackageInstaller(private val activity: FlutterActivity) {
    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures.orEmpty().map {
            MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) }
        }.toSet()
    }

    @Suppress("DEPRECATION")
    fun validate(path: String): File {
        val allowed = File(activity.cacheDir, "BobTVUpdates").canonicalFile
        val file = File(path).canonicalFile
        require(file.parentFile == allowed && file.extension == "apk" && file.isFile && file.length() in 1_000_000L..2_000_000_000L) { "Invalid update file" }
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val candidate = activity.packageManager.getPackageArchiveInfo(file.path, flags) ?: error("Invalid APK")
        val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
        require(candidate.packageName == activity.packageName) { "APK package identity mismatch" }
        require(certificates(candidate).isNotEmpty() && certificates(candidate) == certificates(installed)) { "APK publisher signature mismatch" }
        val candidateVersion = if (Build.VERSION.SDK_INT >= 28) candidate.longVersionCode else candidate.versionCode.toLong()
        val installedVersion = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else installed.versionCode.toLong()
        require(candidateVersion > installedVersion) { "APK must be newer than the installed version" }
        return file
    }

    fun install(path: String): Map<String, Boolean> {
        val file = validate(path)
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            return mapOf("permissionRequired" to true)
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
        return mapOf("started" to true)
    }
}
