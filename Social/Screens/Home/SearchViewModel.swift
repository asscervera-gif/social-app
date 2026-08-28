//
//  SearchViewModel.swift
//  Social
//
//  Hallazgo real: comparando con Instagram/TikTok/Snapchat, las tres
//  tienen un buscador de personas por nombre — SOCIAL no tenía NINGUNA
//  forma de encontrar a alguien salvo la cámara de proximidad (UWB, solo
//  gente físicamente cerca) o la cuadrícula de Match (candidatos
//  aleatorios, sin control del usuario). `profiles_select_public`
//  (0002_rls.sql) ya permite leer nombre/avatar de cualquier perfil.
//  Equivalente de SearchViewModel.kt.
//
//  Hallazgo real (esta pasada): las tres apps también dejan buscar por
//  etiqueta/hashtag (Explorar de Instagram, búsqueda de TikTok) — un texto
//  que empieza por "#" busca en `posts.caption` en vez de en perfiles,
//  mismo criterio ya construido y compiler-verificado en la versión
//  Kotlin equivalente. `posts_select` (0002_rls.sql) ya permite leer
//  cualquier post público, sin columna ni RPC nuevos.
//

import Foundation

private struct BlockRow: Decodable { let blocked_id: UUID }

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var results: [Profile] = []
    @Published var postResults: [Post] = []
    @Published var errorMessage: String?
    // Seguir un hashtag real, comparado con Instagram/TikTok/X -- ver
    // 0144_hashtag_follows.sql. `nil` mientras no se ha comprobado
    // todavía para el hashtag actual. Equivalente de
    // SearchViewModel.kt.isFollowingCurrentHashtag.
    @Published var isFollowingCurrentHashtag: Bool?

    private var searchTask: Task<Void, Never>?

    private struct HashtagFollowRow: Decodable { let hashtag: String }
    private struct NewHashtagFollow: Encodable { let user_id: UUID; let hashtag: String }

    func toggleFollowHashtag(_ tag: String) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        let normalized = tag.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "#", with: "")
        guard !normalized.isEmpty else { return }
        let currentlyFollowing = isFollowingCurrentHashtag == true
        do {
            if currentlyFollowing {
                try await SupabaseManager.shared.client
                    .from("hashtag_follows")
                    .delete()
                    .eq("user_id", value: userID)
                    .eq("hashtag", value: normalized)
                    .execute()
                isFollowingCurrentHashtag = false
            } else {
                try await SupabaseManager.shared.client
                    .from("hashtag_follows")
                    .insert(NewHashtagFollow(user_id: userID, hashtag: normalized))
                    .execute()
                isFollowingCurrentHashtag = true
            }
        } catch {
            errorMessage = "No se pudo actualizar el hashtag seguido."
        }
    }

    private func loadFollowingState(tag: String) async {
        let normalized = tag.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "#", with: "")
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id, !normalized.isEmpty else {
            isFollowingCurrentHashtag = nil
            return
        }
        let row: HashtagFollowRow? = try? await SupabaseManager.shared.client
            .from("hashtag_follows")
            .select("hashtag")
            .eq("user_id", value: userID)
            .eq("hashtag", value: normalized)
            .single()
            .execute()
            .value
        isFollowingCurrentHashtag = row != nil
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            postResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                results = []
                await searchHashtag(tag: String(text.trimmingCharacters(in: .whitespaces).dropFirst()))
            } else {
                postResults = []
                await search(text: text)
            }
        }
    }

    private func searchHashtag(tag: String) async {
        guard !tag.isEmpty else {
            postResults = []
            isFollowingCurrentHashtag = nil
            return
        }
        await loadFollowingState(tag: tag)
        do {
            // Hallazgo real: a diferencia de la búsqueda de perfiles (sí
            // excluye bloqueados), esta búsqueda por hashtag no filtraba
            // publicaciones de gente que has bloqueado — `posts_select`
            // excluye correctamente `is_social_only`, pero no sabe nada
            // de `blocks`, que es puramente un refuerzo de cliente en
            // esta app. Mismo hallazgo y mismo fix ya aplicados en la
            // versión Kotlin equivalente.
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await SupabaseManager.shared.client
                .from("blocks")
                .select()
                .execute()
                .value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }
            let matches: [Post] = try await SupabaseManager.shared.client
                .from("posts")
                .select()
                .ilike("caption", pattern: "%#\(tag)%")
                .order("created_at", ascending: false)
                .limit(30)
                .execute()
                .value
            // Archivar publicaciones real (0076_archive_posts.sql),
            // comparado con Instagram/Facebook: `posts_select` deja ver
            // la propia publicación archivada al propio autor (para
            // poder gestionarla en "Tus publicaciones"), pero no debería
            // seguir apareciendo en resultados de búsqueda ni para él
            // mismo -- mismo criterio ya aplicado al feed principal.
            postResults = matches.filter { !blockedIDs.contains($0.authorID) && $0.archivedAt == nil }
        } catch {
            errorMessage = "No se pudo buscar."
        }
    }

    private func search(text: String) async {
        do {
            let myID = try? await SupabaseManager.shared.client.auth.session.user.id

            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await SupabaseManager.shared.client
                .from("blocks")
                .select()
                .execute()
                .value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            // Mismo filtro real ya aplicado en Home/Match
            // (`eq("is_invisible", value: false)`) — sin esto, el modo
            // invisible (SafetyManager.setInvisible) solo ocultaba a
            // alguien de la cámara de proximidad, no del buscador por
            // nombre, dejando la promesa de privacidad a medias. Mismo
            // hallazgo real ya corregido en la versión Kotlin equivalente.
            //
            // Nombre de usuario único real (@handle, 0073_profile_username.sql),
            // comparado con Instagram/Twitter/TikTok -- el buscador solo
            // encontraba por nombre para mostrar (no único, puede repetirse),
            // ahora también por @usuario. `.or("col.op.val,col.op.val")` es
            // el mismo patrón ya usado y compiler-verificado en esta app
            // (DuelHistoryViewModel.swift, SocialsListViewModel.swift,
            // ChatListViewModel.swift), no una firma nueva sin confirmar.
            let matches: [Profile] = try await SupabaseManager.shared.client
                .from("profiles")
                .select()
                .or("display_name.ilike.%\(text)%,username.ilike.%\(text)%")
                .eq("is_invisible", value: false)
                .limit(30)
                .execute()
                .value
            results = matches.filter { $0.id != myID && !blockedIDs.contains($0.id) }
        } catch {
            errorMessage = "No se pudo buscar."
        }
    }
}
