package io.github.clubanderson.clubtivi

import android.content.Context
import java.io.File
import java.security.MessageDigest

object BobTvClientSubtitles {
    private const val MODEL = "ggml-base.en-q5_1.bin"
    private const val TINY = "ggml-tiny.en-q5_1.bin"
    private const val TINY_SHA = "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b"
    private const val SHA = "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f"
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
        val model = File(directory, MODEL)
        if (!model.isFile || digest(model) != SHA) {
            val temporary = File(directory, "$MODEL.partial")
            try {
                checkNotNull(modelInput(context, MODEL)).use { input ->
                    temporary.outputStream().use { output -> input.copyTo(output) }
                }
                check(digest(temporary) == SHA)
                check(temporary.renameTo(model))
            } finally { temporary.delete() }
        }
        val paths = mutableMapOf("asr" to asr.absolutePath, "remux" to remux.absolutePath, "model" to model.absolutePath)
        val optimized = File(native, "libbobtv_client_asr_avx2.so")
        if (optimized.canExecute()) paths["asrFast"] = optimized.absolutePath
        if (modelInput(context, TINY)?.use { true } == true) {
            val tiny = File(directory, TINY)
            if (!tiny.isFile || digest(tiny) != TINY_SHA) {
                val temporary = File(directory, "$TINY.partial")
                try {
                    checkNotNull(modelInput(context, TINY)).use { input -> temporary.outputStream().use { output -> input.copyTo(output) } }
                    check(digest(temporary) == TINY_SHA)
                    check(temporary.renameTo(tiny))
                } finally { temporary.delete() }
            }
            paths["tinyModel"] = tiny.absolutePath
            if (!android.os.Process.is64Bit()) paths["preferTiny"] = "true"
        }
        return paths
    }
}
