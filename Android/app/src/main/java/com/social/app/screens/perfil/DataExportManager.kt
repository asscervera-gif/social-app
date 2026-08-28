package com.social.app.screens.perfil

import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * "Descargar tus datos" real, comparado con Instagram/Facebook/Twitter-X
 * ("Download Your Information") -- hallazgo real, confirmado con `grep`
 * de "export"/"download_data" sin ningún resultado en todo el repo:
 * `AjustesScreen.kt` ya cubre toggles de privacidad reales (recibos de
 * lectura, última conexión, ubicación...) pero ninguna forma real de
 * exportar los datos propios, pese a que `privacy_policy_es.md` habla de
 * transparencia con los datos del usuario.
 *
 * Alcance deliberado: perfil propio + publicaciones propias + comentarios
 * propios (posts y reels) -- un export representativo, no exhaustivo de
 * cada tabla del esquema (eso sería una ronda propia). Todo filtrado por
 * `auth.uid()` real, reutilizando RLS ya existente (nunca hace falta
 * `service_role`, el propio usuario ya puede leer sus filas).
 */
class DataExportManager {

    @Serializable
    private data class ProfileRow(
        val id: String,
        @SerialName("display_name") val displayName: String,
        val bio: String? = null,
        val username: String? = null,
        @SerialName("created_at") val createdAt: String? = null
    )

    @Serializable
    private data class PostRow(
        val id: String,
        val caption: String? = null,
        @SerialName("media_url") val mediaUrl: String? = null,
        @SerialName("created_at") val createdAt: String = ""
    )

    @Serializable
    private data class CommentRow(
        val id: String,
        val body: String,
        @SerialName("created_at") val createdAt: String = ""
    )

    @Serializable
    private data class ExportPayload(
        val profile: ProfileRow?,
        val posts: List<PostRow>,
        val comments: List<CommentRow>,
        @SerialName("reel_comments") val reelComments: List<CommentRow>,
        @SerialName("exported_at") val exportedAt: String
    )

    /** Devuelve el JSON real ya serializado, o null si no hay sesión. */
    suspend fun buildExportJson(): String? {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return null
        val client = SupabaseManager.client

        val profile = try {
            client.from("profiles")
                .select(columns = Columns.raw("id,display_name,bio,username,created_at")) { filter { eq("id", userId) } }
                .decodeSingleOrNull<ProfileRow>()
        } catch (e: Exception) {
            null
        }
        val posts = try {
            client.from("posts")
                .select(columns = Columns.raw("id,caption,media_url,created_at")) { filter { eq("author_id", userId) } }
                .decodeList<PostRow>()
        } catch (e: Exception) {
            emptyList()
        }
        val comments = try {
            client.from("comments")
                .select(columns = Columns.raw("id,body,created_at")) { filter { eq("author_id", userId) } }
                .decodeList<CommentRow>()
        } catch (e: Exception) {
            emptyList()
        }
        val reelComments = try {
            client.from("reel_comments")
                .select(columns = Columns.raw("id,body,created_at")) { filter { eq("author_id", userId) } }
                .decodeList<CommentRow>()
        } catch (e: Exception) {
            emptyList()
        }

        val payload = ExportPayload(profile, posts, comments, reelComments, java.time.Instant.now().toString())
        return Json { prettyPrint = true }.encodeToString(payload)
    }
}
