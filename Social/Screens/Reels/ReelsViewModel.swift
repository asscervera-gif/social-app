//
//  ReelsViewModel.swift
//  Social
//
//  Reels (0050_reels.sql) -- primera UI de cliente real sobre el backend de
//  la ronda anterior (tabla + RLS + contadores + avisos ya construidos y
//  verificados con 79/79 tests, pero sin ningún punto de la interfaz que
//  los usara). Mismo patrón exacto que HomeViewModel (feed de posts):
//  bloqueo de cliente, autores resueltos en lote, likes con toggle
//  optimista. Equivalente de ReelsViewModel.kt.
//

import Foundation

struct Reel: Codable, Identifiable {
    let id: UUID
    let authorID: UUID
    var videoURL: String
    var thumbnailURL: String?
    var caption: String?
    var isSocialOnly: Bool
    var likeCount: Int
    var commentCount: Int
    var viewCount: Int
    var createdAt: String
    // Desactivar los comentarios de un reel, comparado con Instagram/
    // TikTok -- los comentarios previos se quedan, solo se cierra la
    // puerta a comentarios NUEVOS (0086_disable_comments.sql).
    var commentsDisabled: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case authorID = "author_id"
        case videoURL = "video_url"
        case thumbnailURL = "thumbnail_url"
        case caption
        case isSocialOnly = "is_social_only"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case viewCount = "view_count"
        case createdAt = "created_at"
        case commentsDisabled = "comments_disabled"
    }
}

@MainActor
final class ReelsViewModel: ObservableObject {
    @Published var reels: [Reel] = []
    @Published var authorProfiles: [UUID: Profile] = [:]
    @Published var likedReelIDs: Set<UUID> = []
    @Published var isLoading = false
    @Published var isUploading = false
    @Published var errorMessage: String?

    private struct BlockRow: Decodable { let blocked_id: UUID }
    private struct LikedReelRow: Decodable { let reel_id: UUID }

    /// Abrir un reel concreto real desde un aviso de "like"/"comentario",
    /// comparado con Instagram/TikTok: `reel_like`/`reel_comment`/
    /// `reel_comment_like` ya llevan `reel_id` real en su payload
    /// (0050_reels.sql / 0070_notify_comment_like_post_reference.sql),
    /// pero tocar el aviso no llevaba a ningún sitio porque `load()` solo
    /// trae los 30 reels más recientes -- el reel real del aviso podría no
    /// estar ahí. Si no aparece en esa ventana, se pide aparte y se
    /// antepone a la lista -- mismo criterio de "solo lo necesario" que
    /// PostDetailView.swift. Sujeto a las mismas reglas RLS/bloqueo reales
    /// que el resto del feed: si la política lo deniega, sencillamente no
    /// se añade. Equivalente de ReelsViewModel.kt.load(pinnedReelId:).
    func load(pinnedReelID: UUID? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = SupabaseManager.shared.client
            let myID = try? await client.auth.session.user.id

            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await client.from("blocks").select().execute().value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            let allReels: [Reel] = try await client.from("reels")
                .select()
                .order("created_at", ascending: false)
                .limit(30)
                .execute()
                .value
            var recentReels = allReels.filter { !blockedIDs.contains($0.authorID) }

            if let pinnedReelID, !recentReels.contains(where: { $0.id == pinnedReelID }) {
                let pinned: Reel? = try? await client.from("reels")
                    .select()
                    .eq("id", value: pinnedReelID)
                    .single()
                    .execute()
                    .value
                if let pinned, !blockedIDs.contains(pinned.authorID) {
                    recentReels = [pinned] + recentReels
                }
            }
            reels = recentReels

            let authorIDs = Array(Set(reels.map { $0.authorID }))
            if !authorIDs.isEmpty {
                let profiles: [Profile] = try await client.from("profiles")
                    .select("id,display_name,avatar_url,avatar_config")
                    .in("id", values: authorIDs)
                    .execute()
                    .value
                authorProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            }

            if let myID {
                let likedRows: [LikedReelRow] = try await client.from("reel_likes")
                    .select("reel_id")
                    .eq("user_id", value: myID)
                    .execute()
                    .value
                likedReelIDs = Set(likedRows.map { $0.reel_id })
            }
        } catch {
            errorMessage = "No se pudieron cargar los reels."
        }
    }

    /// Mismo patrón exacto que HomeViewModel.toggleLike(), aplicado a
    /// reel_likes en vez de likes.
    func toggleLike(_ reel: Reel) async {
        let currentlyLiked = likedReelIDs.contains(reel.id)
        if currentlyLiked {
            likedReelIDs.remove(reel.id)
        } else {
            likedReelIDs.insert(reel.id)
        }
        if let index = reels.firstIndex(where: { $0.id == reel.id }) {
            reels[index].likeCount = max(0, reels[index].likeCount + (currentlyLiked ? -1 : 1))
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewReelLike: Encodable {
            let reel_id: UUID
            let user_id: UUID
        }
        do {
            if currentlyLiked {
                try await SupabaseManager.shared.client
                    .from("reel_likes")
                    .delete()
                    .eq("reel_id", value: reel.id)
                    .eq("user_id", value: userID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("reel_likes")
                    .insert(NewReelLike(reel_id: reel.id, user_id: userID))
                    .execute()
                AnalyticsManager.track("reel_liked")
            }
        } catch {
            // Restricción unique(reel_id, user_id): si ya existía el like,
            // Postgrest devuelve un error -- el estado deseado ya se
            // cumple, mismo criterio que HomeViewModel.toggleLike().
        }
    }

    /// Desactivar los comentarios de un reel propio real, comparado con
    /// Instagram/TikTok -- los comentarios que ya existían se quedan tal
    /// cual, solo se cierra la puerta a comentarios NUEVOS
    /// (`reel_comments_insert_own`, 0086_disable_comments.sql, lo
    /// garantiza también del lado del servidor). `reels_write_own` ya es
    /// `for all`, mismo criterio que toggleArchive() en posts: sin
    /// política RLS nueva. Equivalente de
    /// ReelsViewModel.kt.toggleCommentsDisabled().
    ///
    /// Aviso real de un fallo real: esta función faltaba por completo en
    /// una pasada anterior -- `ReelsView.swift` ya la llamaba, pero nunca
    /// se llegó a definir aquí, y sin compilador Swift real en este
    /// entorno (sin Mac/Xcode) no se detectó hasta que el CI real de
    /// GitHub Actions lo rechazó con un error real de "no dynamic
    /// member". Corregido desde ese log real, no adivinado.
    func toggleCommentsDisabled(_ reel: Reel) async {
        let newValue = !reel.commentsDisabled
        if let index = reels.firstIndex(where: { $0.id == reel.id }) {
            reels[index].commentsDisabled = newValue
        }
        do {
            try await SupabaseManager.shared.client
                .from("reels")
                .update(["comments_disabled": newValue])
                .eq("id", value: reel.id)
                .execute()
        } catch {
            errorMessage = "No se pudo cambiar el estado de los comentarios."
            await load()
        }
    }

    /// Mismo patrón exacto que HomeViewModel.commentAdded()/
    /// commentRemoved(), para que ReelsView refleje el contador sin
    /// recargar todo el feed.
    func commentAdded(reelID: UUID) {
        if let index = reels.firstIndex(where: { $0.id == reelID }) {
            reels[index].commentCount += 1
        }
    }

    func commentRemoved(reelID: UUID) {
        if let index = reels.firstIndex(where: { $0.id == reelID }) {
            reels[index].commentCount = max(0, reels[index].commentCount - 1)
        }
    }

    /// Sube el vídeo real al bucket `media` (StorageUploader.uploadVideo,
    /// mismo patrón que las fotos de publicaciones) e inserta la fila real
    /// en `reels`. Sin miniatura real todavía: `thumbnail_url` se deja sin
    /// fijar -- generar un fotograma real necesitaría decodificar el
    /// vídeo (AVAssetImageGenerator), hueco real documentado, no fingido
    /// con un color aleatorio. Equivalente de ReelsViewModel.kt.upload().
    func upload(videoData: Data, fileExtension: String, caption: String, isSocialOnly: Bool) async -> Bool {
        isUploading = true
        defer { isUploading = false }
        struct NewReel: Encodable {
            let author_id: UUID
            let video_url: String
            let caption: String?
            let is_social_only: Bool
        }
        do {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
            let videoURL = try await StorageUploader.uploadVideo(data: videoData, fileExtension: fileExtension, userID: userID)
            try await SupabaseManager.shared.client
                .from("reels")
                .insert(NewReel(author_id: userID, video_url: videoURL, caption: caption.isEmpty ? nil : caption, is_social_only: isSocialOnly))
                .execute()
            AnalyticsManager.track("reel_created")
            await load()
            return true
        } catch {
            errorMessage = "No se pudo publicar el reel."
            return false
        }
    }
}
