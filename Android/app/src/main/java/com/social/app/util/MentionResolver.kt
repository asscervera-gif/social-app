package com.social.app.util

import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.serialization.Serializable

/**
 * Resuelve un "@usuario" real (0073_profile_username.sql) a su id de
 * perfil real -- compartido entre captions/comentarios de posts y reels,
 * mismo criterio de "compartir en vez de duplicar" que
 * MentionHashtagText.kt (la consulta es idéntica en las cuatro
 * superficies). Sin resultado si el username ya no existe (cuenta
 * borrada) -- se resuelve en silencio, mismo criterio ya aplicado a
 * shared_post_id/story_id en mensajes (0069/0071).
 */
class MentionResolver {

    @Serializable
    private data class UsernameRow(val id: String)

    suspend fun resolveProfileId(username: String): String? {
        val normalized = username.trim().lowercase()
        if (normalized.isEmpty()) return null
        return try {
            SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id")) { filter { eq("username", normalized) } }
                .decodeSingleOrNull<UsernameRow>()
                ?.id
        } catch (e: Exception) {
            null
        }
    }
}
