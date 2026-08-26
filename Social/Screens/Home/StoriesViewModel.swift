//
//  StoriesViewModel.swift
//  Social
//
//  Historias — hueco documentado toda la sesión como "bloqueado por
//  Storage", ya no es cierto (ver StorageUploader.swift). El esquema y RLS
//  ya estaban completos desde 0001/0002 (`expires_at default now()+24h`,
//  `stories_select using (expires_at > now())` filtra caducadas a nivel de
//  base de datos, sin necesitar lógica de cliente) — solo faltaba el
//  cliente entero: crear y ver. Equivalente de StoriesViewModel.kt.
//

import Foundation

struct StoryRow: Decodable, Identifiable {
    let id: UUID
    let author_id: UUID
    let media_url: String
    let created_at: String
}

struct StoryGroup: Identifiable {
    var id: UUID { authorID }
    let authorID: UUID
    let authorName: String
    let stories: [StoryRow]
}

@MainActor
final class StoriesViewModel: ObservableObject {
    @Published var groups: [StoryGroup] = []
    @Published var errorMessage: String?
    @Published var isUploading = false

    private struct BlockRow: Decodable { let blocked_id: UUID }

    func load() async {
        do {
            // RLS ya excluye las caducadas (`expires_at > now()`) — no
            // hace falta filtrar en cliente.
            //
            // Hallazgo real: Historias nunca filtraba historias de gente
            // bloqueada — mismo refuerzo de privacidad ya aplicado en
            // Home/Match/Find/Search/ChatList/Guardados/Tus socials.
            // Mismo fix ya construido en la versión Kotlin equivalente.
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await SupabaseManager.shared.client
                .from("blocks")
                .select()
                .execute()
                .value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            let allStories: [StoryRow] = try await SupabaseManager.shared.client
                .from("stories")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value
            let stories = allStories.filter { !blockedIDs.contains($0.author_id) }

            let byAuthor = Dictionary(grouping: stories, by: { $0.author_id })
            var newGroups: [StoryGroup] = []
            for (authorID, authorStories) in byAuthor {
                let name = await displayName(id: authorID) ?? "Perfil"
                newGroups.append(StoryGroup(authorID: authorID, authorName: name, stories: authorStories))
            }
            groups = newGroups
        } catch {
            errorMessage = "No se pudieron cargar las historias."
        }
    }

    private func displayName(id: UUID) async -> String? {
        struct NameRow: Decodable { let display_name: String }
        let row: NameRow? = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("display_name")
            .eq("id", value: id)
            .single()
            .execute()
            .value
        return row?.display_name
    }

    /// "Quién vio tu historia" (0053_story_views.sql), comparado con
    /// Instagram/Snapchat/WhatsApp Status. No se registra al ver tu propia
    /// historia. `unique(story_id, viewer_id)` puede lanzar si ya se
    /// registró antes -- no es un error real, el estado deseado ya se
    /// cumple. Equivalente de StoriesViewModel.kt.recordView().
    func recordView(_ story: StoryRow) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id,
              userID != story.author_id else { return }
        struct NewStoryView: Encodable {
            let story_id: UUID
            let viewer_id: UUID
        }
        try? await SupabaseManager.shared.client
            .from("story_views")
            .insert(NewStoryView(story_id: story.id, viewer_id: userID))
            .execute()
    }

    struct StoryViewer: Identifiable {
        let id: UUID
        let displayName: String
    }

    /// Solo tiene sentido llamarlo sobre tu propia historia -- RLS
    /// (`story_views_select_own_story`) ya lo exige, esta función no
    /// duplica esa comprobación en cliente. Equivalente de
    /// StoriesViewModel.kt.loadViewers().
    func loadViewers(storyID: UUID) async -> [StoryViewer] {
        struct ViewerIDRow: Decodable { let viewer_id: UUID }
        struct ViewerNameRow: Decodable { let id: UUID; let display_name: String }
        guard let viewerRows: [ViewerIDRow] = try? await SupabaseManager.shared.client
            .from("story_views")
            .select("viewer_id")
            .eq("story_id", value: storyID)
            .execute()
            .value else { return [] }
        let viewerIDs = viewerRows.map { $0.viewer_id }
        guard !viewerIDs.isEmpty else { return [] }
        guard let profiles: [ViewerNameRow] = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("id,display_name")
            .in("id", values: viewerIDs)
            .execute()
            .value else { return [] }
        return profiles.map { StoryViewer(id: $0.id, displayName: $0.display_name) }
    }

    func createStory(imageData: Data) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let url = try await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: userID)
            struct NewStory: Encodable {
                let author_id: UUID
                let media_url: String
            }
            try await SupabaseManager.shared.client
                .from("stories")
                .insert(NewStory(author_id: userID, media_url: url))
                .execute()
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: publicar una historia no se registraba,
            // dejando un hueco en cualquier análisis de qué tan usada
            // está la función.
            AnalyticsManager.track("story_created")
            await load()
        } catch {
            errorMessage = "No se pudo subir la historia."
        }
    }

    /// Responder a una historia real (0071_message_story_reply.sql),
    /// comparado con Instagram/WhatsApp Status/Snapchat -- manda la
    /// respuesta como un mensaje directo real a quien publicó la
    /// historia. `chatID` ya resuelto por el llamador (StoriesBar.swift,
    /// vía `SocialLinkManager.getOrCreateChat`, el mismo usado para
    /// "Enviar mensaje" desde un aviso) -- esta función solo inserta el
    /// mensaje. Equivalente de StoriesViewModel.kt.sendReply().
    func sendReply(chatID: UUID, storyID: UUID, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return false }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
        struct NewStoryReply: Encodable {
            let chat_id: UUID
            let sender_id: UUID
            let body: String
            let story_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("messages")
                .insert(NewStoryReply(chat_id: chatID, sender_id: userID, body: trimmed, story_id: storyID))
                .execute()
            AnalyticsManager.track("story_replied")
            return true
        } catch {
            return false
        }
    }
}
