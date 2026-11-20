package io.github.clubanderson.clubtivi

import android.content.Context
import java.io.File
import java.security.MessageDigest

object BobTvClientSubtitles {
    private const val MODEL = "ggml-base-q5_1.bin"
    private const val TINY = "ggml-tiny-q5_1.bin"
    private const val TINY_SHA = "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
    private const val SHA = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
    private const val LEGACY_MODEL = "ggml-base.en-q5_1.bin"
    private const val LEGACY_TINY = "ggml-tiny.en-q5_1.bin"
    private const val LEGACY_SHA = "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f"
    private const val LEGACY_TINY_SHA = "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b"
    private fun digest(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private fun modelInput(context: Context, name: String): java.io.InputStream? {
        return context.classLoader.getResourceAsStream("bobtv-client-subtitles/$name")
            ?: try { context.assets.open("ClientASR/$name") } catch (_: java.io.IOException) { null }
    }
    @Synchronized fun resources(context: Context): Map<String, String> {
        val native = File(context.applicationInfo.nativeLibraryDir)
        val asr = File(native, "libbobtv_client_asr.so")
        val remux = File(native, "libbobtv_client_remux.so")
        check(asr.canExecute() && remux.canExecute())
        val directory = File(context.filesDir, "ClientASR").apply { mkdirs() }
        val multilingual = modelInput(context, MODEL)?.use { true } == true
        val modelName = if (multilingual) MODEL else LEGACY_MODEL
        val modelSha = if (multilingual) SHA else LEGACY_SHA
        val model = File(directory, modelName)
        if (!model.isFile || digest(model) != modelSha) {
            val temporary = File(directory, "$modelName.partial")
            try {
                checkNotNull(modelInput(context, modelName)).use { input ->
                    temporary.outputStream().use { output -> input.copyTo(output) }
                }
                check(digest(temporary) == modelSha)
                check(temporary.renameTo(model))
            } finally { temporary.delete() }
        }
        val paths = mutableMapOf("asr" to asr.absolutePath, "remux" to remux.absolutePath, "model" to model.absolutePath)
        val optimized = File(native, "libbobtv_client_asr_avx2.so")
        if (optimized.canExecute()) paths["asrFast"] = optimized.absolutePath
        val tinyName = if (multilingual) TINY else LEGACY_TINY
        val tinySha = if (multilingual) TINY_SHA else LEGACY_TINY_SHA
        if (modelInput(context, tinyName)?.use { true } == true) {
            val tiny = File(directory, tinyName)
            if (!tiny.isFile || digest(tiny) != tinySha) {
                val temporary = File(directory, "$tinyName.partial")
                try {
                    checkNotNull(modelInput(context, tinyName)).use { input -> temporary.outputStream().use { output -> input.copyTo(output) } }
                    check(digest(temporary) == tinySha)
                    check(temporary.renameTo(tiny))
                } finally { temporary.delete() }
            }
            paths["tinyModel"] = tiny.absolutePath
            if (!android.os.Process.is64Bit() ||
                (android.os.Build.SUPPORTED_ABIS.firstOrNull() == "x86_64" && !optimized.canExecute())) {
                paths["preferTiny"] = "true"
            }
        }
        return paths
    }
}
