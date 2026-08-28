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
    @Published var recommended: [(profile: Profile, compatibility: Int?, requestSent: Bool)] = []
    private var cachedMyInterests: Set<String> = []
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
    // Comparado con Instagram/Facebook: publicaciones con varias fotos
    // (0055_post_media.sql) -- `Post.mediaURL` sigue siendo la primera,
    // aquí solo las adicionales, indexadas por post.
    @Published var extraMediaByPost: [UUID: [String]] = [:]

    // Encuesta real en una publicación normal, comparado con Twitter/X/
    // Facebook -- ver 0113_post_polls.sql, mismo diseño exacto que las
    // encuestas de historias (StoriesViewModel.storyPolls). Equivalente
    // de HomeViewModel.kt.postPolls/myPostPollVotes.
    struct PostPollRow: Decodable, Identifiable {
        let id: UUID
        let post_id: UUID
        let question: String
        let options: [String]
        var vote_counts: [Int] = []
    }
    @Published var postPolls: [UUID: PostPollRow] = [:]
    @Published var myPostPollVotes: [UUID: Int] = [:]

    // Repostear una publicación real, comparado con Twitter/X/Facebook --
    // ver 0127_post_reposts.sql. Alcance deliberado: esta ronda cubre el
    // toggle + contador + aviso real al autor, igual que el equivalente
    // Kotlin (HomeViewModel.kt.toggleRepost) -- mostrar el repost dentro
    // del feed de tus propios seguidores queda para una ronda futura,
    // mismo criterio de fase inicial ya usado varias veces esta sesión
    // (p. ej. muted_feed_keywords solo cubrió el feed antes de extenderse
    // a Reels).
    @Published var repostedPostIDs: Set<UUID> = []
    @Published var repostCounts: [UUID: Int] = [:]

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

            // Palabras silenciadas reales en TU PROPIO feed, comparado
            // con Twitter/X ("Muted words") -- distinto de
            // `muted_keywords` (0078, filtra comentarios AJENOS en TUS
            // publicaciones): esto oculta publicaciones AJENAS de TU
            // feed. Resuelto en cliente, nunca en RLS -- mismo criterio
            // que el filtro de bloqueados de arriba. Mismo fix ya
            // construido en la versión Kotlin equivalente. Ver
            // 0116_muted_feed_keywords.sql.
            struct MutedFeedKeywordsRow: Decodable { let muted_feed_keywords: [String] }
            var mutedFeedKeywords: [String] = []
            if let userID = try? await client.auth.session.user.id,
               let row: MutedFeedKeywordsRow = try? await client
                .from("profiles")
                .select("muted_feed_keywords")
                .eq("id", value: userID)
                .single()
                .execute()
                .value {
                mutedFeedKeywords = row.muted_feed_keywords
            }

            // Silenciar una cuenta real, comparado con Instagram/
            // Twitter/X/Facebook -- sus publicaciones dejan de verse en
            // tu feed sin dejar de seguirla, sin bloquearla y sin que se
            // entere nunca. Resuelto en cliente, nunca en RLS -- mismo
            // criterio exacto que mutedFeedKeywords de arriba. Ver
            // SafetyManager.muteAccount(), 0126_muted_accounts.sql.
            struct MutedAccountRow: Decodable { let muted_id: UUID }
            var mutedAccountIDs: Set<UUID> = []
            if let rows: [MutedAccountRow] = try? await client.from("muted_accounts").select("muted_id").execute().value {
                mutedAccountIDs = Set(rows.map { $0.muted_id })
            }

            let allFeed: [Post] = try await client
                .from("posts")
                .select()
                .order("created_at", ascending: false)
                .limit(30)
                .execute()
                .value
            // Archivar publicaciones real (0076_archive_posts.sql),
            // comparado con Instagram/Facebook: `posts_select` ya excluye
            // una archivada para CUALQUIER OTRO usuario, pero el propio
            // autor SIEMPRE la ve vía RLS (para poder gestionarla en "Tus
            // publicaciones") -- sin filtrar aquí en cliente, el propio
            // autor seguiría viendo su publicación archivada mezclada en
            // su propio feed principal, justo lo que archivar debería
            // evitar. Mismo fix ya construido en la versión Kotlin
            // equivalente.
            feed = allFeed.filter { post in
                !blockedIDs.contains(post.authorID) && !mutedAccountIDs.contains(post.authorID) && post.archivedAt == nil &&
                    !mutedFeedKeywords.contains { word in
                        post.caption?.range(of: word, options: .caseInsensitive) != nil
                    }
            }

            let feedIDs = feed.map { $0.id }
            if !feedIDs.isEmpty {
                struct PostMediaRow: Decodable { let post_id: UUID; let media_url: String }
                if let rows: [PostMediaRow] = try? await client
                    .from("post_media")
                    .select("post_id,media_url")
                    .in("post_id", values: feedIDs)
                    .order("position", ascending: true)
                    .execute()
                    .value {
                    extraMediaByPost = Dictionary(grouping: rows, by: { $0.post_id })
                        .mapValues { group in group.map { $0.media_url } }
                }

                // Encuesta real en una publicación normal, comparado con
                // Twitter/X/Facebook -- se carga junto con el resto del
                // feed, igual que extraMediaByPost arriba.
                if let pollRows: [PostPollRow] = try? await client
                    .from("post_polls")
                    .select("id,post_id,question,options,vote_counts")
                    .in("post_id", values: feedIDs)
                    .execute()
                    .value {
                    postPolls = Dictionary(uniqueKeysWithValues: pollRows.map { ($0.post_id, $0) })
                    struct MyVoteRow: Decodable { let poll_id: UUID; let option_index: Int }
                    // `voter_id = userID` explícito -- sin este filtro, la
                    // política post_poll_votes_select también deja ver
                    // TODOS los votos de una encuesta propia (para el
                    // autor real de la publicación), y eso contaminaría
                    // myPostPollVotes con votos ajenos. Mismo filtro real
                    // ya usado en StoriesViewModel.swift.
                    if !pollRows.isEmpty, let userID = try? await client.auth.session.user.id,
                       let voteRows: [MyVoteRow] = try? await client
                        .from("post_poll_votes")
                        .select("poll_id,option_index")
                        .eq("voter_id", value: userID)
                        .in("poll_id", values: pollRows.map { $0.id })
                        .execute()
                        .value {
                        myPostPollVotes = Dictionary(uniqueKeysWithValues: voteRows.map { ($0.poll_id, $0.option_index) })
                    } else {
                        myPostPollVotes = [:]
                    }
                } else {
                    postPolls = [:]
                    myPostPollVotes = [:]
                }
            }

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
                struct RepostRow: Decodable { let post_id: UUID; let user_id: UUID }
                if !feedIDs.isEmpty,
                   let rows: [RepostRow] = try? await client
                    .from("post_reposts")
                    .select("post_id,user_id")
                    .in("post_id", values: feedIDs)
                    .execute()
                    .value {
                    repostedPostIDs = Set(rows.filter { $0.user_id == userID }.map { $0.post_id })
                    repostCounts = Dictionary(grouping: rows, by: { $0.post_id }).mapValues { $0.count }
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
            // Cacheado a nivel de instancia -- ver compatibilityFor(), que
            // reutiliza este mismo cálculo para mostrar el % de
            // compatibilidad en la cabecera de cada post del feed, no solo
            // en el carrusel de "Recomendados" (hallazgo real comparado
            // con SOCIAL_APP.html: el boceto muestra el % también en cada
            // publicación).
            cachedMyInterests = myInterests
            recommended = candidates.map { profile in
                (profile: profile, compatibility: estimatedCompatibility(with: profile, myInterests: myInterests), requestSent: false)
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

    /// Expone el mismo cálculo para el autor de un post del feed -- mismo
    /// criterio real que SOCIAL_APP.html (compat% en la cabecera de cada
    /// publicación, no solo en "Recomendados"). Equivalente de
    /// HomeViewModel.kt.compatibilityFor().
    func compatibilityFor(_ profile: Profile) -> Int? {
        estimatedCompatibility(with: profile, myInterests: cachedMyInterests)
    }

    /// Solicitar ver la compatibilidad real de alguien que la tiene privada
    /// -- mismo patrón exacto que MatchViewModel.requestCompatibility(),
    /// hasta ahora solo construido en Match. Comparado con SOCIAL_APP.html:
    /// "Recomendados" (y ahora la cabecera de cada post) mostraba "?%" sin
    /// ninguna forma real de pedir verlo, a diferencia de Match.
    func requestCompatibility(profileID: UUID) async {
        if let index = recommended.firstIndex(where: { $0.profile.id == profileID }) {
            recommended[index].requestSent = true
        }
        struct NewRequest: Encodable {
            let requester_id: UUID
            let target_id: UUID
        }
        do {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            try await SupabaseManager.shared.client
                .from("compat_requests")
                .insert(NewRequest(requester_id: userID, target_id: profileID))
                .execute()
            AnalyticsManager.track("compat_request_sent")
        } catch {
            errorMessage = "No se pudo enviar la solicitud de compatibilidad."
        }
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

    /// Toggle real de repost/unrepost, comparado con Twitter/X/Facebook --
    /// mismo patrón exacto que toggleLike(). El aviso real al autor lo
    /// dispara `private.notify_new_repost()` (0127_post_reposts.sql), no
    /// este código. Equivalente de HomeViewModel.kt.toggleRepost().
    func toggleRepost(_ post: Post) async {
        let currentlyReposted = repostedPostIDs.contains(post.id)
        if currentlyReposted {
            repostedPostIDs.remove(post.id)
            repostCounts[post.id] = max(0, (repostCounts[post.id] ?? 1) - 1)
        } else {
            repostedPostIDs.insert(post.id)
            repostCounts[post.id] = (repostCounts[post.id] ?? 0) + 1
        }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewRepost: Encodable {
            let post_id: UUID
            let user_id: UUID
        }
        do {
            if currentlyReposted {
                try await SupabaseManager.shared.client
                    .from("post_reposts")
                    .delete()
                    .eq("post_id", value: post.id)
                    .eq("user_id", value: userID)
                    .execute()
            } else {
                try await SupabaseManager.shared.client
                    .from("post_reposts")
                    .insert(NewRepost(post_id: post.id, user_id: userID))
                    .execute()
                AnalyticsManager.track("post_reposted")
            }
        } catch {
            // Restricción unique(post_id, user_id): mismo criterio de
            // tolerancia ya usado en toggleLike()/toggleSave().
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

    /// Votar/cambiar de opción en la encuesta de una publicación,
    /// comparado con Twitter/X/Facebook -- mismo patrón exacto que
    /// StoriesViewModel.voteOnPoll() (0100). Equivalente de
    /// HomeViewModel.kt.voteOnPostPoll().
    func voteOnPostPoll(pollID: UUID, optionIndex: Int) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        myPostPollVotes[pollID] = optionIndex
        struct NewPostPollVote: Encodable {
            let poll_id: UUID
            let voter_id: UUID
            let option_index: Int
        }
        do {
            try await SupabaseManager.shared.client
                .from("post_poll_votes")
                .upsert(NewPostPollVote(poll_id: pollID, voter_id: userID, option_index: optionIndex), onConflict: "poll_id,voter_id")
                .execute()
            if let updated: PostPollRow = try? await SupabaseManager.shared.client
                .from("post_polls")
                .select("id,post_id,question,options,vote_counts")
                .eq("id", value: pollID)
                .single()
                .execute()
                .value {
                postPolls[updated.post_id] = updated
            }
        } catch {
            errorMessage = "No se pudo registrar el voto."
        }
    }
}
