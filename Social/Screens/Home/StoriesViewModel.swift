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
    // "Mejores amigos" real (0075_close_friends_stories.sql), comparado
    // con Instagram/Snapchat -- decodificado aunque el cliente no lo
    // necesite para filtrar (RLS ya decide quién ve qué fila en
    // absoluto), solo para poder mostrarlo si hiciera falta más adelante.
    var visibility: String = "everyone"
    // Texto sobre la Historia + @menciones reales ahí, comparado con
    // Instagram/TikTok/Snapchat -- ver 0143_story_caption_mentions.sql.
    var caption: String? = nil
}

// Adhesivo de pregunta real en una historia ("Pregúntame algo"),
// comparado con Instagram -- ver 0099_story_questions.sql. Equivalente
// de StoryQuestionRow en StoriesViewModel.kt.
struct StoryQuestionRow: Decodable, Identifiable {
    let id: UUID
    let story_id: UUID
    let prompt: String
}

// Encuesta real en una historia, comparado con Instagram/Twitter/X --
// ver 0100_story_polls.sql. Equivalente de StoryPollRow en
// StoriesViewModel.kt.
struct StoryPollRow: Decodable, Identifiable {
    let id: UUID
    let story_id: UUID
    let question: String
    let options: [String]
    var vote_counts: [Int] = []
}

// Destacados reales de historias en el perfil, comparado con Instagram --
// ver 0101_story_highlights.sql. Equivalente de StoryHighlightRow en
// StoriesViewModel.kt.
struct StoryHighlightRow: Decodable, Identifiable {
    let id: UUID
    let author_id: UUID
    let title: String
    let cover_story_id: UUID?
}

struct StoryGroup: Identifiable {
    var id: UUID { authorID }
    let authorID: UUID
    let authorName: String
    let stories: [StoryRow]
    // Silenciar las historias de alguien sin dejar de seguirlo, comparado
    // con Instagram/Snapchat -- preferencia personal de orden/atenuación
    // en la propia bandeja, NO control de acceso
    // (0085_muted_story_authors.sql, `stories_select` no cambia).
    var isMuted: Bool = false
}

@MainActor
final class StoriesViewModel: ObservableObject {
    @Published var groups: [StoryGroup] = []
    @Published var errorMessage: String?
    @Published var isUploading = false
    // Silenciar las historias de alguien sin dejar de seguirlo, comparado
    // con Instagram/Snapchat (0085_muted_story_authors.sql).
    @Published var mutedAuthorIDs: Set<UUID> = []
    // Adhesivo de pregunta real en una historia ("Pregúntame algo"),
    // comparado con Instagram -- una por story_id como mucho, ver
    // 0099_story_questions.sql. Equivalente de
    // StoriesViewModel.kt.storyQuestions.
    @Published var storyQuestions: [UUID: StoryQuestionRow] = [:]
    // Encuesta real en una historia, comparado con Instagram/Twitter/X --
    // una por story_id como mucho, ver 0100_story_polls.sql. Equivalente
    // de StoriesViewModel.kt.storyPolls.
    @Published var storyPolls: [UUID: StoryPollRow] = [:]
    // Voto propio por encuesta (clave = poll id), comparado con
    // Instagram/Twitter/X -- ver StoriesViewModel.kt.myPollVotes.
    @Published var myPollVotes: [UUID: Int] = [:]
    // Destacados reales de historias en el perfil, comparado con
    // Instagram -- solo los propios (para poder elegir a cuál añadir una
    // historia real activa desde el visor), ver 0101_story_highlights.sql.
    // Equivalente de StoriesViewModel.kt.myHighlights.
    @Published var myHighlights: [StoryHighlightRow] = []

    private struct BlockRow: Decodable { let blocked_id: UUID }
    private struct MutedStoryAuthorRow: Decodable { let muted_id: UUID }

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

            // Silenciar las historias de alguien sin dejar de seguirlo,
            // comparado con Instagram/Snapchat
            // (0085_muted_story_authors.sql) -- lista propia, nunca
            // visible para nadie más.
            var mutedIDs: Set<UUID> = []
            if let userID = try? await SupabaseManager.shared.client.auth.session.user.id,
               let mutedRows: [MutedStoryAuthorRow] = try? await SupabaseManager.shared.client
                   .from("muted_story_authors")
                   .select("muted_id")
                   .eq("muter_id", value: userID)
                   .execute()
                   .value {
                mutedIDs = Set(mutedRows.map { $0.muted_id })
            }
            mutedAuthorIDs = mutedIDs

            // Adhesivo de pregunta real en una historia ("Pregúntame
            // algo"), comparado con Instagram -- se carga junto con el
            // resto de historias, en vez de una consulta aparte por cada
            // una al abrirlas.
            if stories.isEmpty {
                storyQuestions = [:]
            } else if let questionRows: [StoryQuestionRow] = try? await SupabaseManager.shared.client
                .from("story_questions")
                .select("id,story_id,prompt")
                .in("story_id", values: stories.map { $0.id })
                .execute()
                .value {
                storyQuestions = Dictionary(uniqueKeysWithValues: questionRows.map { ($0.story_id, $0) })
            } else {
                storyQuestions = [:]
            }

            // Encuesta real en una historia, comparado con
            // Instagram/Twitter/X -- se carga junto con el resto de
            // historias, igual que storyQuestions arriba.
            if stories.isEmpty {
                storyPolls = [:]
                myPollVotes = [:]
            } else if let pollRows: [StoryPollRow] = try? await SupabaseManager.shared.client
                .from("story_polls")
                .select("id,story_id,question,options,vote_counts")
                .in("story_id", values: stories.map { $0.id })
                .execute()
                .value {
                storyPolls = Dictionary(uniqueKeysWithValues: pollRows.map { ($0.story_id, $0) })
                struct MyVoteRow: Decodable { let poll_id: UUID; let option_index: Int }
                // `voter_id = userID` explícito -- sin este filtro, la
                // política story_poll_votes_select también deja ver TODOS
                // los votos de una encuesta propia (para el autor real de
                // la historia), y eso contaminaría myPollVotes con votos
                // ajenos. Mismo filtro real que la versión Kotlin
                // equivalente (StoriesViewModel.kt.load()).
                if !pollRows.isEmpty, let userID = try? await SupabaseManager.shared.client.auth.session.user.id,
                   let voteRows: [MyVoteRow] = try? await SupabaseManager.shared.client
                    .from("story_poll_votes")
                    .select("poll_id,option_index")
                    .eq("voter_id", value: userID)
                    .in("poll_id", values: pollRows.map { $0.id })
                    .execute()
                    .value {
                    myPollVotes = Dictionary(uniqueKeysWithValues: voteRows.map { ($0.poll_id, $0.option_index) })
                } else {
                    myPollVotes = [:]
                }
            } else {
                storyPolls = [:]
                myPollVotes = [:]
            }

            // Destacados reales de historias en el perfil, comparado con
            // Instagram -- solo los propios, para poder elegir a cuál
            // añadir una historia activa desde el visor.
            if let userID = try? await SupabaseManager.shared.client.auth.session.user.id,
               let highlightRows: [StoryHighlightRow] = try? await SupabaseManager.shared.client
                .from("story_highlights")
                .select("id,author_id,title,cover_story_id")
                .eq("author_id", value: userID)
                .execute()
                .value {
                myHighlights = highlightRows
            } else {
                myHighlights = []
            }

            let byAuthor = Dictionary(grouping: stories, by: { $0.author_id })
            var newGroups: [StoryGroup] = []
            for (authorID, authorStories) in byAuthor {
                let name = await displayName(id: authorID) ?? "Perfil"
                newGroups.append(StoryGroup(authorID: authorID, authorName: name, stories: authorStories, isMuted: mutedIDs.contains(authorID)))
            }
            // Silenciado se manda al final de la bandeja, atenuado en el
            // cliente -- nunca oculto del todo, mismo criterio real que
            // Instagram/Snapchat (a diferencia de un bloqueo).
            groups = newGroups.sorted { !$0.isMuted && $1.isMuted }
        } catch {
            errorMessage = "No se pudieron cargar las historias."
        }
    }

    /// Silenciar/dejar de silenciar las historias reales de una persona,
    /// comparado con Instagram/Snapchat -- NO es un bloqueo ni afecta
    /// `stories_select`, solo el orden/atenuación en la propia bandeja
    /// (`muted_story_authors_insert`/`_delete`, 0085_muted_story_authors.sql,
    /// ya garantizan del lado del servidor que solo se toca la lista
    /// propia). Equivalente de StoriesViewModel.kt.toggleMuteAuthor().
    func toggleMuteAuthor(_ authorID: UUID) async {
        let currentlyMuted = mutedAuthorIDs.contains(authorID)
        if currentlyMuted {
            mutedAuthorIDs.remove(authorID)
        } else {
            mutedAuthorIDs.insert(authorID)
        }
        if let index = groups.firstIndex(where: { $0.authorID == authorID }) {
            groups[index].isMuted = !currentlyMuted
        }
        groups.sort { !$0.isMuted && $1.isMuted }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            if currentlyMuted {
                try await SupabaseManager.shared.client
                    .from("muted_story_authors")
                    .delete()
                    .eq("muter_id", value: userID)
                    .eq("muted_id", value: authorID)
                    .execute()
            } else {
                struct NewMutedStoryAuthor: Encodable {
                    let muter_id: UUID
                    let muted_id: UUID
                }
                try await SupabaseManager.shared.client
                    .from("muted_story_authors")
                    .insert(NewMutedStoryAuthor(muter_id: userID, muted_id: authorID))
                    .execute()
            }
        } catch {
            // No crítico: si falla, la próxima carga real reconcilia el
            // estado con el servidor.
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

    // "Mejores amigos" real (0075_close_friends_stories.sql), comparado
    // con Instagram/Snapchat -- `visibility` elegido por el usuario al
    // subir, "everyone" por defecto (mismo comportamiento de siempre).
    /// [questionPrompt] es opcional -- el adhesivo de pregunta real
    /// ("Pregúntame algo", 0099_story_questions.sql), comparado con
    /// Instagram, no es obligatorio en ninguna historia. Equivalente de
    /// StoriesViewModel.kt.createStory().
    /// [pollQuestion]/[pollOptions] son opcionales -- la encuesta real
    /// ("Encuesta", 0100_story_polls.sql), comparado con
    /// Instagram/Twitter/X, no es obligatoria en ninguna historia, e
    /// independiente del adhesivo de pregunta ([questionPrompt]) --
    /// pueden coexistir en la misma historia. Equivalente de
    /// StoriesViewModel.kt.createStory().
    func createStory(imageData: Data, visibility: String = "everyone", caption: String? = nil, questionPrompt: String? = nil, pollQuestion: String? = nil, pollOptions: [String] = []) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let url = try await StorageUploader.uploadImage(data: imageData, fileExtension: "jpg", userID: userID)
            struct NewStory: Encodable {
                let author_id: UUID
                let media_url: String
                let visibility: String
                // Texto sobre la Historia + @menciones reales ahí,
                // comparado con Instagram/TikTok/Snapchat -- ver
                // 0143_story_caption_mentions.sql.
                let caption: String?
            }
            // Mismo límite real que posts_caption_length
            // (0023_text_length_limits.sql).
            let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2200)
            let finalCaption = (trimmedCaption?.isEmpty ?? true) ? nil : String(trimmedCaption!)
            let insertedStory: StoryRow = try await SupabaseManager.shared.client
                .from("stories")
                .insert(NewStory(author_id: userID, media_url: url, visibility: visibility, caption: finalCaption))
                .select()
                .single()
                .execute()
                .value
            // Mismo límite real del CHECK de story_questions.prompt
            // (0099_story_questions.sql): 200 caracteres.
            let trimmedPrompt = questionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            if let trimmedPrompt, !trimmedPrompt.isEmpty {
                struct NewStoryQuestion: Encodable {
                    let story_id: UUID
                    let prompt: String
                }
                try await SupabaseManager.shared.client
                    .from("story_questions")
                    .insert(NewStoryQuestion(story_id: insertedStory.id, prompt: String(trimmedPrompt)))
                    .execute()
            }
            // Mismo límite real del CHECK de story_polls (2-4 opciones,
            // 0100_story_polls.sql) -- opciones vacías se descartan antes
            // de comprobar el mínimo, igual que un espacio en blanco no
            // cuenta como una opción real.
            let trimmedQuestion = pollQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            let trimmedOptions = pollOptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let trimmedQuestion, !trimmedQuestion.isEmpty, trimmedOptions.count >= 2 {
                struct NewStoryPoll: Encodable {
                    let story_id: UUID
                    let question: String
                    let options: [String]
                }
                try await SupabaseManager.shared.client
                    .from("story_polls")
                    .insert(NewStoryPoll(story_id: insertedStory.id, question: String(trimmedQuestion), options: Array(trimmedOptions.prefix(4))))
                    .execute()
            }
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

    /// Responder en privado a la pregunta real de una historia ajena
    /// ("Pregúntame algo"), comparado con Instagram -- a diferencia de
    /// sendReply() (arriba), esto NO manda un mensaje de chat normal:
    /// solo el autor real de la historia ve la respuesta, con quién la
    /// escribió (`story_question_responses_select`,
    /// 0099_story_questions.sql). Equivalente de
    /// StoriesViewModel.kt.respondToQuestion().
    func respondToQuestion(questionID: UUID, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return false }
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
        struct NewStoryQuestionResponse: Encodable {
            let question_id: UUID
            let responder_id: UUID
            let body: String
        }
        do {
            try await SupabaseManager.shared.client
                .from("story_question_responses")
                .insert(NewStoryQuestionResponse(question_id: questionID, responder_id: userID, body: trimmed))
                .execute()
            AnalyticsManager.track("story_question_answered")
            return true
        } catch {
            return false
        }
    }

    struct StoryQuestionResponse: Identifiable {
        let id = UUID()
        let responderName: String
        let body: String
    }

    /// Solo tiene sentido llamarlo sobre una pregunta de tu propia
    /// historia -- RLS (`story_question_responses_select`) ya lo exige,
    /// esta función no duplica esa comprobación en cliente. Mismo patrón
    /// que loadViewers(). Equivalente de
    /// StoriesViewModel.kt.loadQuestionResponses().
    func loadQuestionResponses(questionID: UUID) async -> [StoryQuestionResponse] {
        struct ResponseRow: Decodable { let responder_id: UUID; let body: String }
        struct ResponderNameRow: Decodable { let id: UUID; let display_name: String }
        guard let rows: [ResponseRow] = try? await SupabaseManager.shared.client
            .from("story_question_responses")
            .select("responder_id,body")
            .eq("question_id", value: questionID)
            .execute()
            .value else { return [] }
        guard !rows.isEmpty else { return [] }
        let names: [ResponderNameRow] = (try? await SupabaseManager.shared.client
            .from("profiles")
            .select("id,display_name")
            .in("id", values: rows.map { $0.responder_id })
            .execute()
            .value) ?? []
        let namesByID = Dictionary(uniqueKeysWithValues: names.map { ($0.id, $0.display_name) })
        return rows.map { StoryQuestionResponse(responderName: namesByID[$0.responder_id] ?? "Alguien", body: $0.body) }
    }

    /// Votar (o cambiar de opción) en una encuesta real de una historia,
    /// comparado con Instagram/Twitter/X -- `unique(poll_id, voter_id)`
    /// en 0100_story_polls.sql hace que un segundo voto sea un cambio de
    /// opción, no un voto duplicado, de ahí el upsert. `vote_counts` en
    /// storyPolls se refresca leyendo de vuelta la fila (el trigger real
    /// `sync_story_poll_counts` ya recalculó el agregado del lado del
    /// servidor). Equivalente de StoriesViewModel.kt.voteOnPoll().
    func voteOnPoll(pollID: UUID, optionIndex: Int) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        myPollVotes[pollID] = optionIndex
        struct NewPollVote: Encodable {
            let poll_id: UUID
            let voter_id: UUID
            let option_index: Int
        }
        do {
            try await SupabaseManager.shared.client
                .from("story_poll_votes")
                .upsert(NewPollVote(poll_id: pollID, voter_id: userID, option_index: optionIndex), onConflict: "poll_id,voter_id")
                .execute()
            if let updated: StoryPollRow = try? await SupabaseManager.shared.client
                .from("story_polls")
                .select("id,story_id,question,options,vote_counts")
                .eq("id", value: pollID)
                .single()
                .execute()
                .value {
                storyPolls[updated.story_id] = updated
            }
        } catch {
            errorMessage = "No se pudo registrar el voto."
        }
    }

    /// Crea un destacado real NUEVO a partir de una historia real propia
    /// activa, comparado con Instagram -- solo tiene sentido sobre tu
    /// propia historia (RLS ya lo exige por partida doble: dueño real del
    /// destacado Y de la historia, 0101_story_highlights.sql). Alcance
    /// deliberado: siempre crea un destacado nuevo, sin ofrecer añadir a
    /// uno ya existente desde este mismo diálogo -- eso sigue siendo un
    /// hueco real aparte, documentado en LOOP_STATE.md. Equivalente de
    /// StoriesViewModel.kt.createHighlight().
    func createHighlight(storyID: UUID, title: String) async {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        guard !trimmed.isEmpty, let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct NewHighlight: Encodable {
            let author_id: UUID
            let title: String
            let cover_story_id: UUID
        }
        struct NewHighlightItem: Encodable {
            let highlight_id: UUID
            let story_id: UUID
        }
        do {
            let created: StoryHighlightRow = try await SupabaseManager.shared.client
                .from("story_highlights")
                .insert(NewHighlight(author_id: userID, title: trimmed, cover_story_id: storyID))
                .select()
                .single()
                .execute()
                .value
            try await SupabaseManager.shared.client
                .from("story_highlight_items")
                .insert(NewHighlightItem(highlight_id: created.id, story_id: storyID))
                .execute()
            myHighlights.append(created)
            AnalyticsManager.track("story_highlight_created")
        } catch {
            errorMessage = "No se pudo crear el destacado."
        }
    }

    /// Añadir una historia real a un destacado YA EXISTENTE, comparado
    /// con Instagram -- cierra el hueco deliberado documentado en
    /// createHighlight() de arriba. Misma tabla real
    /// (story_highlight_items, 0101_story_highlights.sql), sin
    /// migración: el propio RLS ya exige ser dueño real tanto del
    /// destacado como de la historia. Equivalente de
    /// StoriesViewModel.kt.addStoryToHighlight().
    func addStoryToHighlight(highlightID: UUID, storyID: UUID) async {
        struct NewHighlightItem: Encodable {
            let highlight_id: UUID
            let story_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("story_highlight_items")
                .insert(NewHighlightItem(highlight_id: highlightID, story_id: storyID))
                .execute()
            AnalyticsManager.track("story_added_to_highlight")
        } catch {
            errorMessage = "No se pudo añadir al destacado."
        }
    }
}
