package com.social.app.backend

import android.content.Context
import android.net.Uri
import io.github.jan.supabase.storage.storage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * Hallazgo real, segundo hueco raíz más grave de toda la sesión: no había
 * ninguna integración de Storage en ningún sitio del proyecto — Historias,
 * chat multimedia, avatar 3D y fotos en publicaciones llevaban toda la
 * sesión documentados como "bloqueados por falta de Storage", asumiendo
 * (incorrectamente, confirmado ahora) que no había red en este entorno.
 * Bucket "media" público, carpeta por usuario (ver 0015_storage.sql).
 */
object StorageUploader {

    /** Sube el contenido de [uri] a `media/{userId}/{uuid}.{ext}` y devuelve
     * la URL pública real. `contentResolver` lee los bytes en memoria — las
     * fotos de un post/avatar no son tan grandes como para justificar
     * streaming, mismo criterio que el resto de subidas de esta app. */
    suspend fun uploadImage(context: Context, uri: Uri, userId: String): String = withContext(Dispatchers.IO) {
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("No se pudo leer la imagen.")
        val extension = context.contentResolver.getType(uri)?.substringAfterLast("/") ?: "jpg"
        val path = "$userId/${UUID.randomUUID()}.$extension"
        SupabaseManager.client.storage.from("media").upload(path, bytes)
        SupabaseManager.client.storage.from("media").publicUrl(path)
    }

    /** Sube bytes ya generados (sin `Uri`/`File` real de por medio) --
     * mismo patrón exacto ya usado dentro de `uploadVideoThumbnail`
     * (comprimir un `Bitmap` a JPEG en memoria y subir el array
     * resultante), extraído aquí como función reutilizable real para
     * "Compartir el resultado de un duelo como Historia"
     * (DuelResultScreen.kt) -- una tarjeta generada en memoria, nunca un
     * archivo elegido por el usuario. */
    suspend fun uploadBytes(bytes: ByteArray, userId: String, extension: String): String = withContext(Dispatchers.IO) {
        val path = "$userId/${UUID.randomUUID()}.$extension"
        SupabaseManager.client.storage.from("media").upload(path, bytes)
        SupabaseManager.client.storage.from("media").publicUrl(path)
    }

    /** Última pieza de "chat funcional con fotos, voz, reacciones, read
     * receipts" — mensajes de voz nativos (MediaRecorder, ver
     * ChatViewModel.sendVoiceNote), grabados a un archivo local .m4a antes
     * de subirlos, mismo bucket/patrón que las fotos. */
    suspend fun uploadAudioFile(file: java.io.File, userId: String): String = withContext(Dispatchers.IO) {
        val bytes = file.readBytes()
        val path = "$userId/${UUID.randomUUID()}.m4a"
        SupabaseManager.client.storage.from("media").upload(path, bytes)
        SupabaseManager.client.storage.from("media").publicUrl(path)
    }

    /** Reels (0050_reels.sql) -- `uploadImage` ya era genérico de verdad
     * (lee el tipo MIME real de la `Uri`, no asume que sea una foto), pero
     * llamarlo "uploadImage" para subir un vídeo confundiría a quien lea
     * el sitio donde se usa. Mismo criterio que `uploadAudio` en
     * StorageUploader.swift: reutiliza la lógica tal cual. */
    suspend fun uploadVideo(context: Context, uri: Uri, userId: String): String = uploadImage(context, uri, userId)

    /** Miniatura real de un vídeo de Reels, comparado con TikTok/
     * Instagram Reels/YouTube Shorts -- cierra el hueco deliberado
     * documentado en ReelsViewModel.kt.upload(): `thumbnail_url` se
     * dejaba siempre sin fijar. Decodifica un fotograma real del propio
     * vídeo (`MediaMetadataRetriever`, API nativa de Android, sin
     * dependencia nueva) en vez de fingir con un color de relleno.
     * `null` si el vídeo no tiene ningún fotograma decodificable -- el
     * reel se sigue publicando igual, solo sin miniatura real (mismo
     * criterio de "no bloquear el resto" que el resto de esta app). */
    suspend fun uploadVideoThumbnail(context: Context, uri: Uri, userId: String): String? = withContext(Dispatchers.IO) {
        val retriever = android.media.MediaMetadataRetriever()
        try {
            retriever.setDataSource(context, uri)
            // Fotograma a 1s real (no en 0, que en muchos vídeos reales
            // cae en un frame negro/de transición antes de que arranque
            // el contenido de verdad) -- mismo criterio visual que
            // TikTok/Instagram al elegir portada.
            val frame = retriever.getFrameAtTime(1_000_000L, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: retriever.getFrameAtTime(0L, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return@withContext null
            val stream = java.io.ByteArrayOutputStream()
            frame.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, stream)
            val path = "$userId/${UUID.randomUUID()}_thumb.jpg"
            SupabaseManager.client.storage.from("media").upload(path, stream.toByteArray())
            SupabaseManager.client.storage.from("media").publicUrl(path)
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }
}
