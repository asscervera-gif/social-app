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
}
