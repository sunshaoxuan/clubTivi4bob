package io.github.clubanderson.clubtivi

import android.content.Context
import java.io.File
import java.security.MessageDigest

object BobTvClientSubtitles {
    private const val MODEL = "ggml-base.en-q5_1.bin"
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
                context.assets.open("ClientASR/$MODEL").use { input ->
                    temporary.outputStream().use { output -> input.copyTo(output) }
                }
                check(digest(temporary) == SHA)
                check(temporary.renameTo(model))
            } finally { temporary.delete() }
        }
        return mapOf("asr" to asr.absolutePath, "remux" to remux.absolutePath, "model" to model.absolutePath)
    }
}
