//
//  HomeViewModel.swift
//  Social
//
//  Estado de la pestaña Home: feed de publicaciones y recomendados con % de
//  compatibilidad. Carga datos desde Supabase.
//
//  Corrección de honestidad: este comentario y una propiedad `stories`
//  afirmaban/insinuaban Historias como si existieran — no hay tabla
//  `stories` consultada en ningún sitio de este archivo ni en HomeView.swift
//  (ver corrección ya aplicada ahí). La propiedad `stories` nunca se asignaba
//  en ningún sitio de este archivo — código muerto, eliminada.
//

import Foundation

@MainActor
final class HomeViewModel: ObservableObject {

    @Published var feed: [Post] = []
    @Published var recommended: [(profile: Profile, compatibility: Int?)] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var savedPostIDs: Set<UUID> = []
    // Hallazgo real: no había forma de quitar un like, comparado con
    // cualquier app grande — `like()` solo incrementaba el contador local
    // para siempre, mientras `likes` (constraint unique) se quedaba en una
    // sola fila real. El corazón nunca reflejaba si YA le habías dado like.
    @Published var likedPostIDs: Set<UUID> = []
    // Hallazgo real, comparado con cualquier app grande: la tarjeta del
    // feed nunca mostraba QUIÉN publicó cada post -- ni nombre, ni avatar,
    // ni forma de tocar para ver su perfil. `posts` no lleva el perfil
    // embebido, así que se resuelve aparte con un solo select por los
    // authorID distintos del feed cargado (no N+1). Equivalente de
    // HomeViewModel.kt.authorProfiles.
    @Published var authorProfiles: [UUID: Profile] = [:]

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let client = SupabaseManager.shared.client

            // Hallazgo real: el feed principal nunca filtraba
            // publicaciones de gente que has bloqueado — a diferencia de
            // Match/Find/Search (sí lo hacen), bloquear a alguien no le
            // ocultaba sus publicaciones del feed, el sitio que más se
            // mira de toda la app. Movido aquí arriba (antes solo se
            // calculaba más abajo, para "Recomendados") para poder
            // aplicarlo también al feed. Mismo hallazgo y mismo fix ya
            // aplicados en la versión Kotlin equivalente.
            struct BlockRow: Decodable { let blocked_id: UUID }
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await client.from("blocks").select().execute().value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            let allFeed: [Post] = try await client
                .from("posts")
                .select()
                .order("created_at", ascending: false)
                .limit(30)
                .execute()
                .value
            feed = allFeed.filter { !blockedIDs.contains($0.authorID) }

            let authorIDs = Array(Set(feed.map { $0.authorID }))
            if !authorIDs.isEmpty,
               let authors: [Profile] = try? await client
                   .from("profiles")
                   .select()
                   .in("id", values: authorIDs)
                   .execute()
                   .value {
                authorProfiles = Dictionary(uniqueKeysWithValues: authors.map { ($0.id, $0) })
            }

            let userID = try? await client.auth.session.user.id

            if let userID {
                struct SavedPostRow: Decodable { let post_id: UUID }
                if let rows: [SavedPostRow] = try? await client
                    .from("saved_posts")
                    .select()
                    .eq("user_id", value: userID)
                    .execute()
                    .value {
                    savedPostIDs = Set(rows.map { $0.post_id })
                }
                struct LikedPostRow: Decodable { let post_id: UUID }
                if let rows: [LikedPostRow] = try? await client
                    .from("likes")
                    .select()
                    .eq("user_id", value: userID)
                    .execute()
                    .value {
                    likedPostIDs = Set(rows.map { $0.post_id })
                }
            }
            let myInterests: Set<String>
            if let userID,
               let me: Profile = try? await client.from("profiles").select().eq("id", value: userID).single().execute().value {
                myInterests = Set(me.interests)
            } else {
                myInterests = []
            }

            // `blockedIDs` ya se calculó arriba (reutilizado también para
            // el feed) — mismo criterio que MatchViewModel.swift: a quien
            // bloqueas seguía apareciendo en Recomendados. Solo se puede
            // filtrar "a quién he bloqueado yo" — RLS de `blocks` no deja
            // ver quién me bloqueó a mí, límite de privacidad correcto.

            // Mismo fallo de privacidad corregido que en MatchViewModel.swift:
            // sin este filtro, un perfil en modo invisible o el propio usuario
            // aparecían igualmente entre los "Recomendados".
            var candidatesQuery = client.from("profiles").select().eq("is_invisible", value: false)
            if let userID {
                candidatesQuery = candidatesQuery.neq("id", value: userID)
            }
            let allCandidates: [Profile] = try await candidatesQuery
                .limit(10)
                .execute()
                .value
            let candidates = allCandidates.filter { !blockedIDs.contains($0.id) }
            // Misma heurística de solapamiento de intereses que
            // MatchViewModel.estimatedCompatibility — ver el comentario allí
            // sobre por qué no hay otra fuente real de "% con un desconocido".
            recommended = candidates.map { profile in
                (profile: profile, compatibility: estimatedCompatibility(with: profile, myInterests: myInterests))
            }
        } catch {
            errorMessage = "No se pudo cargar el feed: \(error.localizedDescription)"
        }
    }

    private func estimatedCompatibility(with profile: Profile, myInterests: Set<String>) -> Int? {
        guard profile.compatPublic else { return nil }
        let theirInterests = Set(profile.interests)
        guard !myInterests.isEmpty, !theirInterests.isEmpty else { return nil }
        let intersection = myInterests.intersection(theirInterests).count
        let union = myInterests.union(theirInterests).count
        guard union > 0 else { return nil }
        return Int((Double(intersection) / Double(union)) * 100)
    }

    /// Toggle real de like/unlike — antes era solo `like()`, un botón de un
    /// solo sentido que incrementaba el contador local para siempre sin
    /// saber si ya estaba likeado (ver hallazgo en `likedPostIDs`).
    /// `posts.like_count` lo mantiene sincronizado un trigger
    /// (0007_likes.sql), no este código. Mismo patrón ya correcto de
    /// toggleSave(). Equivalente de HomeViewModel.kt.toggleLike().
    func toggleLike(_ post: Post) async {
        let currentlyLiked = likedPostIDs.contains(post.id)
        if currentlyLiked {
            likedPostIDs.remove(post.id)
        } else {
            likedPostIDs.insert(post.id)
        }
        if let index = feed.firstIndex(where: { $0.id == post.id }) {
            feed[index].likeCount = max(0, feed[index].likeCount + (currentlyLiked ? -1 : 1))
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewLike: Encodable {
            let post_id: UUID
            let user_id: UUID
        }
        do {
            if currentlyLiked {
                try await SupabaseManager.shared.client
                    .from("likes")
                    .delete()
                    .eq("post_id", value: post.id)
                    .eq("user_id", value: userID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("likes")
                    .insert(NewLike(post_id: post.id, user_id: userID))
                    .execute()
                // Hallazgo real, mismo criterio ya aplicado en la versión
                // Kotlin equivalente: dar like es la señal de
                // participación más frecuente de cualquier feed y no se
                // registraba en absoluto. Solo en la dirección de "dar
                // like" (no "quitar").
                AnalyticsManager.track("post_liked")
            }
        } catch {
            // Restricción unique(post_id, user_id): si ya existía el like,
            // Postgrest devuelve un 409 — no es un error real de usuario,
            // el estado deseado ya se cumple (mismo criterio que
            // toggleSave()).
        }
    }

    /// Refleja en el feed el comentario ya persistido por CommentsViewModel
    /// (ver 0008_comments.sql) sin recargar el feed entero — mismo criterio
    /// que like(). Equivalente de HomeViewModel.kt.commentAdded().
    func commentAdded(postID: UUID) {
        if let index = feed.firstIndex(where: { $0.id == postID }) {
            feed[index].commentCount += 1
        }
    }

    /// Contraparte de commentAdded() para el borrado de comentarios recién
    /// añadido (ver CommentsViewModel.deleteComment).
    func commentRemoved(postID: UUID) {
        if let index = feed.firstIndex(where: { $0.id == postID }) {
            feed[index].commentCount = max(0, feed[index].commentCount - 1)
        }
    }

    /// Icono "guardar" antes puramente decorativo (`Image`, sin acción) —
    /// igual que el "like" falso encontrado antes de esta sesión, pero
    /// aquí ni siquiera había un intento de wiring. Toggle real con
    /// persistencia en `saved_posts` (ver 0009_saved_posts.sql, tabla
    /// privada del usuario). Equivalente de HomeViewModel.kt.toggleSave().
    func toggleSave(_ post: Post) async {
        let currentlySaved = savedPostIDs.contains(post.id)
        if currentlySaved {
            savedPostIDs.remove(post.id)
        } else {
            savedPostIDs.insert(post.id)
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewSavedPost: Encodable {
            let post_id: UUID
            let user_id: UUID
        }
        do {
            if currentlySaved {
                try await SupabaseManager.shared.client
                    .from("saved_posts")
                    .delete()
                    .eq("post_id", value: post.id)
                    .eq("user_id", value: userID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("saved_posts")
                    .insert(NewSavedPost(post_id: post.id, user_id: userID))
                    .execute()
                // Hallazgo real, mismo criterio ya aplicado en la versión
                // Kotlin equivalente: guardar tampoco se registraba.
                AnalyticsManager.track("post_saved")
            }
        } catch {
            // Restricción unique(post_id, user_id) en el caso de guardar dos
            // veces seguidas: el estado deseado ya se cumple, no es un error
            // real de usuario (mismo criterio que like()).
        }
    }
}
