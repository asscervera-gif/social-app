package com.social.app.backend.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Modelos serializables que reflejan 1:1 las tablas de
 * supabase/migrations/0001_schema.sql — equivalente Kotlin de Models.swift.
 */

@Serializable
data class Profile(
    val id: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    // Hallazgo real: faltaba este campo por completo — `avatar_config`
    // existe en 0001_schema.sql desde el principio y se consultaba en
    // varias pantallas vía Columns.raw, pero al no estar en el modelo
    // nunca se decodificaba ni se podía pintar. Ver avatar/AvatarView.kt.
    @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null,
    val interests: List<String> = emptyList(),
    val bio: String? = null,
    @SerialName("is_invisible") val isInvisible: Boolean = false,
    @SerialName("location_public") val locationPublic: Boolean = false,
    @SerialName("compat_public") val compatPublic: Boolean = false,
    @SerialName("is_verified") val isVerified: Boolean = false,
    // Hallazgo real (redisenio de Match, ver MatchScreen.kt): la columna
    // existe en 0001_schema.sql desde el principio, pero nada la escribia
    // nunca (ver PrivacySettingsViewModel.kt.publishCurrentLocation, el fix
    // gemelo de este mismo hallazgo) ni la leia fuera de "Find" — el filtro
    // "Cerca" de Match no podia existir de verdad sin esto en el modelo.
    @SerialName("last_lat") val lastLat: Double? = null,
    @SerialName("last_lng") val lastLng: Double? = null,
    @SerialName("created_at") val createdAt: String? = null,
    // Nombre de usuario único real (@handle, 0073_profile_username.sql),
    // comparado con Instagram/Twitter/TikTok.
    val username: String? = null,
    // Enlace externo real en el perfil ("link in bio",
    // 0077_profile_website.sql), comparado con Instagram/TikTok/Twitter.
    @SerialName("website_url") val websiteUrl: String? = null
)

@Serializable
data class Post(
    val id: String,
    @SerialName("author_id") val authorId: String,
    @SerialName("media_url") val mediaUrl: String? = null,
    val caption: String? = null,
    @SerialName("is_social_only") val isSocialOnly: Boolean = false,
    @SerialName("like_count") val likeCount: Int = 0,
    @SerialName("comment_count") val commentCount: Int = 0,
    // Hallazgo real: ningún post mostraba fecha/hora en ningún sitio de la
    // app, comparado con cualquier app grande ("hace 2h", "3d"...) — ni
    // siquiera se decodificaba `created_at` en el modelo.
    @SerialName("created_at") val createdAt: String = "",
    // Hallazgo real, comparado con SOCIAL_APP.html ("Pubs de socials",
    // etiqueta "con Marta"): no había forma de decir con quién se hizo una
    // publicación — 0051_post_social_tags.sql.
    @SerialName("tagged_profile_id") val taggedProfileId: String? = null,
    // Archivar publicaciones real (0076_archive_posts.sql), comparado con
    // Instagram/Facebook -- null significa visible con normalidad.
    @SerialName("archived_at") val archivedAt: String? = null,
    // Desactivar los comentarios de una publicación, comparado con
    // Instagram/TikTok -- los comentarios previos se quedan, solo se
    // cierra la puerta a comentarios NUEVOS (0086_disable_comments.sql).
    @SerialName("comments_disabled") val commentsDisabled: Boolean = false,
    // Ocultar el número de "me gusta" real, comparado con Instagram/
    // Facebook -- el autor sigue viendo su cifra real siempre, solo
    // desaparece el número para los demás (0094_hide_like_count.sql).
    @SerialName("hide_like_count") val hideLikeCount: Boolean = false,
    // Etiqueta de ubicación real (texto libre, no geocodificado),
    // comparado con Instagram/Facebook/Twitter/Snapchat -- ver
    // 0095_post_location_tag.sql.
    @SerialName("location_name") val locationName: String? = null,
    // Marcar contenido como sensible, comparado con Instagram/Twitter/
    // TikTok -- difumina la foto para cualquiera que no sea el autor
    // hasta que toque para revelarla (0096_sensitive_content.sql).
    @SerialName("is_sensitive") val isSensitive: Boolean = false,
    // "¿Quién puede comentar?" real, comparado con Twitter/X/TikTok --
    // 'everyone'/'followers'/'mentioned' (0097_reply_audience.sql).
    @SerialName("reply_audience") val replyAudience: String = "everyone",
    // Fijar una publicación en el perfil (hasta 3), comparado con
    // Instagram -- ver 0106_pin_posts_to_profile.sql.
    @SerialName("pinned_at") val pinnedAt: String? = null,
    // Texto alternativo real (accesibilidad), comparado con Instagram/
    // Facebook/Twitter-X -- describe media_url (siempre la primera/
    // única foto, mismo criterio que 0055_post_media.sql) para lectores
    // de pantalla (TalkBack). Ver 0151_post_alt_text.sql.
    @SerialName("alt_text") val altText: String? = null
)

@Serializable
data class Comment(
    val id: String,
    @SerialName("post_id") val postId: String,
    @SerialName("author_id") val authorId: String,
    val body: String,
    @SerialName("created_at") val createdAt: String,
    // Comparado con Instagram/Twitter/Facebook: dar like a un comentario
    // concreto, no solo a la publicación entera (0054_comment_likes.sql).
    @SerialName("like_count") val likeCount: Int = 0,
    // Fijar un comentario, comparado con Instagram/Twitter -- solo el
    // autor real de la publicación puede cambiarlo (0084_pin_comments.sql).
    @SerialName("is_pinned") val isPinned: Boolean = false,
    // Responder a un comentario concreto (hilo de un nivel), comparado
    // con Instagram/Facebook/Twitter/TikTok -- referencia al comentario
    // real de primer nivel que se responde. Ver 0104_comment_replies.sql.
    @SerialName("parent_comment_id") val parentCommentId: String? = null,
    // Editar un comentario ya publicado, comparado con
    // Instagram/Facebook/Twitter/TikTok -- solo el propio autor del
    // comentario puede cambiarlo (0123_comment_edit.sql).
    @SerialName("edited_at") val editedAt: String? = null
)

// Comparado con Instagram/Facebook: publicaciones con varias fotos
// (0055_post_media.sql). `posts.media_url` sigue siendo la PRIMERA foto (o
// la única); esta tabla guarda solo las adicionales.
@Serializable
data class PostMedia(
    val id: String,
    @SerialName("post_id") val postId: String,
    @SerialName("media_url") val mediaUrl: String,
    val position: Int = 0,
    // Texto alternativo real (accesibilidad) propio de ESTA foto
    // adicional, comparado con Instagram/Facebook/Twitter-X -- ver
    // 0151_post_alt_text.sql.
    @SerialName("alt_text") val altText: String? = null
)

@Serializable
data class SocialLink(
    val id: String,
    @SerialName("requester_id") val requesterId: String,
    @SerialName("addressee_id") val addresseeId: String,
    val status: String
)

@Serializable
data class NotificationEntry(
    val id: String,
    val kind: String,
    val payload: Map<String, String> = emptyMap(),
    @SerialName("read_at") val readAt: String? = null,
    @SerialName("created_at") val createdAt: String
)

@Serializable
data class CompatRequest(
    val id: String,
    @SerialName("requester_id") val requesterId: String,
    @SerialName("target_id") val targetId: String,
    val status: String
)

@Serializable
data class Chat(
    val id: String,
    @SerialName("user_a_id") val userAId: String,
    @SerialName("user_b_id") val userBId: String,
    @SerialName("compatibility_score") val compatibilityScore: Int = 50,
    // Mensajes que desaparecen real, comparado con WhatsApp/Instagram DM
    // -- null = desactivado, en segundos si está activo (86400/604800/
    // 7776000). Ver 0115_disappearing_messages.sql.
    @SerialName("disappearing_seconds") val disappearingSeconds: Int? = null,
    // Fondo de chat por persona, comparado con WhatsApp/Telegram/
    // Messenger -- cada quien ve el suyo propio, ver
    // 0139_chat_wallpaper.sql.
    @SerialName("wallpaper_by_a") val wallpaperByA: String? = null,
    @SerialName("wallpaper_by_b") val wallpaperByB: String? = null,
    // Sonido de notificación por persona, comparado con WhatsApp/Telegram/
    // Messenger/Instagram DM -- ver 0154_chat_notification_sound.sql.
    @SerialName("notification_sound_by_a") val notificationSoundByA: String? = null,
    @SerialName("notification_sound_by_b") val notificationSoundByB: String? = null
)

@Serializable
data class ChatMessage(
    val id: String,
    @SerialName("chat_id") val chatId: String,
    @SerialName("sender_id") val senderId: String,
    val body: String? = null,
    // Hallazgo real: el chat solo soportaba texto — `media_url` opcional
    // (0016_message_media.sql), igual que posts, ahora que Storage existe.
    @SerialName("media_url") val mediaUrl: String? = null,
    @SerialName("created_at") val createdAt: String,
    // Hallazgo real: última pieza real de "chat funcional con fotos, voz,
    // reacciones, read receipts" alcanzable sin infraestructura nueva —
    // mismo patrón que notifications.read_at (0017_message_read_receipts.sql).
    @SerialName("read_at") val readAt: String? = null,
    // Estado real de "Entregado" (✓✓ gris), comparado con WhatsApp --
    // distinto de leído (✓✓ azul). Ver 0117_message_delivered_status.sql.
    @SerialName("delivered_at") val deliveredAt: String? = null,
    // "Eliminar para mí" real, comparado con WhatsApp -- resuelto en el
    // cliente (mismo criterio que muted_feed_keywords, 0116): la fila
    // sigue existiendo de verdad para la otra persona, solo se oculta
    // en MI propia lista. Ver 0118_delete_message_for_me.sql.
    @SerialName("deleted_for") val deletedFor: List<String> = emptyList(),
    // Mensajes de voz — separado de mediaUrl a propósito, ver
    // 0019_message_audio.sql: el cliente necesita distinguir explícitamente
    // reproductor de imagen, no adivinar por la extensión del archivo.
    @SerialName("audio_url") val audioUrl: String? = null,
    // Hallazgo real, comparado con WhatsApp/Telegram/Messenger: un mensaje
    // mal escrito solo se podía borrar entero, nunca corregir -- ver
    // 0049_messages_edit.sql/ChatViewModel.editMessage().
    @SerialName("edited_at") val editedAt: String? = null,
    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat.
    @SerialName("shared_post_id") val sharedPostId: String? = null,
    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat.
    @SerialName("story_id") val storyId: String? = null,
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    @SerialName("is_forwarded") val isForwarded: Boolean = false,
    // Fijar un mensaje real (propio o ajeno) para que aparezca destacado
    // arriba del chat, VISIBLE PARA TODOS los participantes -- a diferencia
    // de starred_messages (totalmente privado), comparado con
    // WhatsApp/Telegram, ver 0089_pin_message.sql.
    @SerialName("pinned_at") val pinnedAt: String? = null,
    @SerialName("pinned_by") val pinnedBy: String? = null,
    // Responder a un mensaje concreto (cita), comparado con
    // WhatsApp/Telegram/iMessage/Instagram DM -- referencia al mensaje
    // real citado, nunca una copia. Ver 0102_message_reply.sql.
    @SerialName("reply_to_message_id") val replyToMessageId: String? = null,
    // Foto para ver una vez, comparado con WhatsApp/Instagram DM/
    // Snapchat -- el propio servidor vacía media_url de verdad en cuanto
    // opened_at pasa de null a no-null (0105_view_once_messages.sql).
    @SerialName("view_once") val viewOnce: Boolean = false,
    @SerialName("opened_at") val openedAt: String? = null,
    // Vídeos reales en el chat, comparado con WhatsApp/Telegram/
    // iMessage -- reutiliza mediaUrl (ya es una URL de Storage real
    // tanto para foto como vídeo). Ver 0121_video_messages.sql.
    @SerialName("is_video") val isVideo: Boolean = false
)

/** Hallazgo de integridad corregido (ver duel-ai/index.ts): antes incluía
 * `correctIndex`, viajando en claro al cliente — cualquiera podía ver la
 * respuesta correcta antes de elegir. Ahora el servidor guarda las
 * preguntas completas en `duel_sessions` y solo manda prompt+options; la
 * puntuación real la calcula el servidor contra esa sesión, no el cliente. */
@Serializable
data class DuelQuestion(
    val prompt: String,
    val options: List<String>
)

/**
 * Videollamada/llamada de voz real (0079_calls.sql), comparado con
 * WhatsApp/Messenger/Instagram -- ver CallManager.kt para el hallazgo
 * completo. `chatId`/`calleeId` nullable y `groupChatId` añadido
 * (0083_group_calls.sql): una llamada es 1:1 XOR de grupo, nunca las dos
 * cosas -- exactamente uno de los dos destinos está presente de verdad
 * (`calls_target_check` lo garantiza también del lado del servidor).
 */
@Serializable
data class Call(
    val id: String,
    @SerialName("chat_id") val chatId: String? = null,
    @SerialName("caller_id") val callerId: String,
    @SerialName("callee_id") val calleeId: String? = null,
    @SerialName("group_chat_id") val groupChatId: String? = null,
    val kind: String,
    @SerialName("room_name") val roomName: String,
    val status: String,
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("ended_at") val endedAt: String? = null
)

/**
 * Una fila por miembro real de una llamada de GRUPO (0083_group_calls.sql)
 * -- mismo motivo que `group_chat_members` frente a
 * `chats.user_a_id/user_b_id`: no hay un único "destinatario" al que
 * apuntar.
 */
@Serializable
data class CallParticipant(
    @SerialName("call_id") val callId: String,
    @SerialName("user_id") val userId: String,
    val status: String,
    @SerialName("joined_at") val joinedAt: String? = null,
    @SerialName("left_at") val leftAt: String? = null
)

@Serializable
data class Duel(
    val id: String,
    @SerialName("chat_id") val chatId: String,
    @SerialName("initiator_id") val initiatorId: String,
    @SerialName("opponent_id") val opponentId: String,
    val questions: List<DuelQuestion>,
    @SerialName("compatibility_delta") val compatibilityDelta: Int? = null,
    val explanation: String? = null,
    @SerialName("is_public") val isPublic: Boolean = false
)
