package com.social.app.chat

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import java.io.File

/**
 * Grabación de voz nativa (`MediaRecorder`, sin SDK de terceros) — última
 * pieza real de "chat funcional con fotos, voz, reacciones, read
 * receipts". AAC en un contenedor MPEG_4 (.m4a), formato estándar
 * reproducible por `MediaPlayer` sin conversión.
 */
class VoiceRecorder(private val context: Context) {

    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null

    fun start(): File {
        val file = File.createTempFile("voice_", ".m4a", context.cacheDir)
        outputFile = file
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        r.setOutputFile(file.absolutePath)
        r.prepare()
        r.start()
        recorder = r
        return file
    }

    /** Devuelve el archivo grabado, o null si no había grabación en curso. */
    fun stop(): File? {
        try {
            recorder?.stop()
        } catch (e: Exception) {
            // stop() puede lanzar si se para casi inmediatamente después de
            // start() (grabación demasiado corta) — no hay audio útil que
            // subir en ese caso.
            return null
        } finally {
            recorder?.release()
            recorder = null
        }
        return outputFile
    }

    fun cancel() {
        try {
            recorder?.stop()
        } catch (e: Exception) {
            // Ignorado — se está descartando de todas formas.
        }
        recorder?.release()
        recorder = null
        outputFile?.delete()
        outputFile = null
    }
}
