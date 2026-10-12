package io.github.clubanderson.clubtivi

import android.os.Build
import android.app.UiModeManager
import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.os.Process
import android.provider.Settings
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "io.github.clubanderson.clubtivi/installer"
    private var deviceChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "installApk" || call.method == "validateApk") {
                val filePath = call.argument<String>("filePath")
                if (filePath != null) {
                    try {
                        val installer = BobTvPackageInstaller(this)
                        if (call.method == "validateApk") {
                            installer.validate(filePath)
                            result.success(true)
                        } else {
                            result.success(installer.install(filePath))
                        }
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARG", "filePath is required", null)
                }
            } else {
                result.notImplemented()
            }
        }
        deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bobtv/device")
        deviceChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(mapOf(
                    "television" to ((getSystemService(UI_MODE_SERVICE) as UiModeManager).currentModeType == Configuration.UI_MODE_TYPE_TELEVISION),
                    "androidId" to Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID),
                    "sdk" to Build.VERSION.SDK_INT,
                    "updatePlatform" to if (Build.SUPPORTED_ABIS.firstOrNull() == "x86_64") "android-x64" else if (Process.is64Bit()) "android-arm64" else "android-arm",
                    "pictureInPicture" to (Build.VERSION.SDK_INT >= 26 && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE))
                ))
                "enterPip" -> {
                    if (Build.VERSION.SDK_INT < 26 || !packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
                        result.success(false)
                    } else {
                        val width = (call.argument<Int>("width") ?: 16).coerceAtLeast(1)
                        val height = (call.argument<Int>("height") ?: 9).coerceAtLeast(1)
                        val ratio = width.toDouble() / height
                        val safeRatio = if (ratio in (1.0 / 2.39)..2.39) Rational(width, height) else Rational(16, 9)
                        try {
                            result.success(enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(safeRatio).build()))
                        } catch (e: Exception) {
                            result.error("PIP_ERROR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onPictureInPictureModeChanged(inPip: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(inPip, newConfig)
        deviceChannel?.invokeMethod("pipChanged", inPip)
    }
}
