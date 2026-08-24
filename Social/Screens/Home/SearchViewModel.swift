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

    private var searchTask: Task<Void, Never>?

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
            return
        }
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
            postResults = matches.filter { !blockedIDs.contains($0.authorID) }
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
            let matches: [Profile] = try await SupabaseManager.shared.client
                .from("profiles")
                .select()
                .ilike("display_name", pattern: "%\(text)%")
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
