//
//  Models.swift
//  Social
//
//  Modelos Codable que reflejan 1:1 las tablas de supabase/migrations/0001_schema.sql.
//

import Foundation

struct Profile: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var avatarURL: String?
    var avatarConfig: [String: String]?
    var interests: [String]
    var bio: String?
    var isInvisible: Bool
    var locationPublic: Bool
    var compatPublic: Bool
    var isVerified: Bool
    var lastLat: Double?
    var lastLng: Double?
    // Hallazgo real (redisenio de Match, ver MatchView.swift): necesario
    // para el filtro real "Nuevos" del boceto — decodificado como String
    // (no Date) para no depender de la estrategia de fecha configurada en
    // SupabaseManager, mismo criterio que Profile.kt.createdAt.
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case avatarConfig = "avatar_config"
        case interests, bio
        case isInvisible = "is_invisible"
        case locationPublic = "location_public"
        case compatPublic = "compat_public"
        case isVerified = "is_verified"
        case lastLat = "last_lat"
        case lastLng = "last_lng"
        case createdAt = "created_at"
    }
}

struct ProfileSection: Codable, Identifiable {
    let id: UUID
    let profileID: UUID
    var sectionKey: String
    var content: [String: String]
    var isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case profileID = "profile_id"
        case sectionKey = "section_key"
        case content
        case isPublic = "is_public"
    }
}

struct Post: Codable, Identifiable {
    let id: UUID
    let authorID: UUID
    var mediaURL: String?
    var caption: String?
    var isSocialOnly: Bool
    var likeCount: Int
    var commentCount: Int
    // Hallazgo real: ningún post mostraba fecha/hora en ningún sitio de la
    // app, comparado con cualquier app grande ("hace 2h", "3d"...).
    var createdAt: String
    // Hallazgo real, comparado con SOCIAL_APP.html ("Pubs de socials",
    // etiqueta "con Marta"): no había forma de decir con quién se hizo una
    // publicación — 0051_post_social_tags.sql.
    var taggedProfileID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case authorID = "author_id"
        case mediaURL = "media_url"
        case caption
        case isSocialOnly = "is_social_only"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case createdAt = "created_at"
        case taggedProfileID = "tagged_profile_id"
    }
}

// Comparado con Instagram/Facebook: publicaciones con varias fotos
// (0055_post_media.sql). `Post.mediaURL` sigue siendo la PRIMERA foto (o
// la única); esta tabla guarda solo las adicionales.
struct PostMedia: Codable, Identifiable {
    let id: UUID
    let postID: UUID
    let mediaURL: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case postID = "post_id"
        case mediaURL = "media_url"
        case position
    }
}

struct SocialLink: Codable, Identifiable {
    let id: UUID
    let requesterID: UUID
    let addresseeID: UUID
    var status: String // "pending" | "accepted" | "declined"

    enum CodingKeys: String, CodingKey {
        case id
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case status
    }
}

struct Chat: Codable, Identifiable {
    let id: UUID
    let userAID: UUID
    let userBID: UUID
    var compatibilityScore: Int
    // Usado para ordenar "Tus chats" por actividad reciente cuando un chat
    // todavía no tiene mensajes (ver ChatListViewModel.load()).
    var createdAt: String
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: no había
    // ninguna forma de quitar una conversación de "Tus chats" -- ver
    // 0044_chats_hide.sql/ChatListViewModel.hideChat().
    var hiddenByA: Bool
    var hiddenByB: Bool
    // Hallazgo real, comparado con WhatsApp/Instagram/Messenger: no había
    // ninguna forma de silenciar una conversación sin salir ni bloquear --
    // ver 0047_message_notify_mute.sql/ChatListViewModel.muteChat().
    var mutedByA: Bool
    var mutedByB: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userAID = "user_a_id"
        case userBID = "user_b_id"
        case compatibilityScore = "compatibility_score"
        case createdAt = "created_at"
        case hiddenByA = "hidden_by_a"
        case hiddenByB = "hidden_by_b"
        case mutedByA = "muted_by_a"
        case mutedByB = "muted_by_b"
    }
}

struct ChatMessage: Codable, Identifiable {
    let id: UUID
    let chatID: UUID
    let senderID: UUID
    var body: String?
    // Hallazgo real: el chat solo soportaba texto — `media_url` opcional
    // (0016_message_media.sql), igual que posts, ahora que Storage existe.
    var mediaURL: String?
    let createdAt: Date
    // Hallazgo real: última pieza de "chat funcional con fotos, voz,
    // reacciones, read receipts" alcanzable sin infraestructura nueva —
    // mismo patrón que notifications.read_at (0017_message_read_receipts.sql).
    var readAt: Date?
    // Última pieza real de "chat funcional con fotos, voz, reacciones,
    // read receipts" — separado de mediaURL a propósito (0019_message_audio.sql):
    // el cliente necesita distinguir reproductor de imagen explícitamente.
    var audioURL: String?
    // Hallazgo real, comparado con WhatsApp/Telegram/Messenger: un mensaje
    // mal escrito solo se podía borrar entero, nunca corregir -- ver
    // 0049_messages_edit.sql/ChatViewModel.editMessage().
    var editedAt: Date?
    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat.
    var sharedPostID: UUID?
    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat.
    var storyID: UUID?
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    var isForwarded: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case senderID = "sender_id"
        case body
        case mediaURL = "media_url"
        case createdAt = "created_at"
        case readAt = "read_at"
        case audioURL = "audio_url"
        case editedAt = "edited_at"
        case sharedPostID = "shared_post_id"
        case storyID = "story_id"
        case isForwarded = "is_forwarded"
    }
}

struct Duel: Codable, Identifiable {
    let id: UUID
    let chatID: UUID
    let initiatorID: UUID
    let opponentID: UUID
    var questions: [DuelQuestion]
    var compatibilityDelta: Int?
    var explanation: String?
    var isPublic: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case initiatorID = "initiator_id"
        case opponentID = "opponent_id"
        case questions
        case compatibilityDelta = "compatibility_delta"
        case explanation
        case isPublic = "is_public"
    }
}

/// Hallazgo de integridad corregido (ver duel-ai/index.ts): antes incluía
/// `correctIndex`, viajando en claro al cliente — cualquiera podía ver la
/// respuesta correcta antes de elegir. Ahora el servidor guarda las
/// preguntas completas en `duel_sessions` y solo manda prompt+options; la
/// puntuación real la calcula el servidor contra esa sesión.
struct DuelQuestion: Codable {
    let prompt: String
    let options: [String]
}
