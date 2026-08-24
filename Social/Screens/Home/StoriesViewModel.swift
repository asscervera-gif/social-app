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
}
