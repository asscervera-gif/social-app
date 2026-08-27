//
//  StoriesBar.swift
//  Social
//
//  Barra de historias en la parte superior de Home — no existía ningún
//  cliente para Historias en ninguna plataforma (ver StoriesViewModel.swift
//  para el hallazgo completo). Equivalente de StoriesBar.kt.
//

import SwiftUI
import PhotosUI

struct StoriesBar: View {
    @StateObject private var viewModel = StoriesViewModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var viewingGroup: StoryGroup?
    @State private var myID: UUID?
    // "Mejores amigos" real (0075_close_friends_stories.sql), comparado
    // con Instagram/Snapchat -- antes de subir, se pregunta la audiencia
    // real en vez de fijarla siempre a "everyone" en silencio.
    @State private var pendingImageData: Data?
    // Adhesivo de pregunta real en una historia ("Pregúntame algo"),
    // comparado con Instagram -- opcional, en el mismo paso real de
    // audiencia en vez de un tercer paso aparte. Ver
    // StoriesViewModel.createStory(), 0099_story_questions.sql.
    @State private var pendingQuestion = ""
    // Encuesta real en una historia, comparado con Instagram/Twitter/X --
    // opcional, mismo paso real de audiencia que la pregunta de arriba.
    // Solo dos opciones en la propia interfaz de creación (el mínimo
    // real que exige 0100_story_polls.sql), igual que StoriesBar.kt.
    @State private var pendingPollQuestion = ""
    @State private var pendingPollOptionA = ""
    @State private var pendingPollOptionB = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    VStack {
                        ZStack {
                            Circle().fill(.gray.opacity(0.15)).frame(width: 60, height: 60)
                            if viewModel.isUploading {
                                ProgressView()
                            } else {
                                Image(systemName: "plus")
                            }
                        }
                        Text("Tu historia").font(.caption2)
                    }
                }
                .onChange(of: selectedPhoto) { newValue in
                    Task {
                        if let data = try? await newValue?.loadTransferable(type: Data.self) {
                            pendingImageData = data
                        }
                    }
                }

                ForEach(viewModel.groups) { group in
                    Button {
                        viewingGroup = group
                    } label: {
                        VStack {
                            AsyncImage(url: URL(string: group.stories.first?.media_url ?? "")) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(.gray.opacity(0.15))
                            }
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                            Text(group.authorName).font(.caption2)
                        }
                        // Silenciar las historias de alguien sin dejar de
                        // seguirlo, comparado con Instagram/Snapchat --
                        // atenuada en la propia bandeja (ya mandada al
                        // final por el ViewModel), nunca oculta del todo
                        // (0085_muted_story_authors.sql).
                        .opacity(group.isMuted ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        .task { await viewModel.load() }
        .fullScreenCover(item: $viewingGroup) { group in
            StoryViewer(group: group, viewModel: viewModel, myID: myID)
        }
        .task { myID = try? await SupabaseManager.shared.client.auth.session.user.id }
        // "Mejores amigos" real (0075_close_friends_stories.sql),
        // comparado con Instagram/Snapchat -- audiencia elegida en el
        // momento de subir, no un ajuste global fijo para todas las
        // historias. Mismo criterio que StoriesBar.kt. Un `.sheet` con
        // `Form` en vez de `.confirmationDialog` real (que no admite un
        // `TextField` propio) para poder añadir también la pregunta
        // opcional en el mismo paso.
        .sheet(isPresented: Binding(
            get: { pendingImageData != nil },
            set: { isPresented in
                if !isPresented {
                    pendingImageData = nil
                    pendingQuestion = ""
                    pendingPollQuestion = ""
                    pendingPollOptionA = ""
                    pendingPollOptionB = ""
                }
            }
        )) {
            NavigationStack {
                Form {
                    Section {
                        Text("\"Mejores amigos\" solo se la enseña a la gente que actives en Ajustes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // Adhesivo de pregunta real en una historia
                    // ("Pregúntame algo"), comparado con Instagram --
                    // opcional.
                    Section {
                        TextField("Añadir pregunta (opcional)", text: $pendingQuestion)
                    }
                    // Encuesta real en una historia, comparado con
                    // Instagram/Twitter/X -- opcional e independiente de
                    // la pregunta de arriba, pueden coexistir.
                    Section {
                        TextField("Añadir encuesta (opcional)", text: $pendingPollQuestion)
                        TextField("Opción 1", text: $pendingPollOptionA)
                        TextField("Opción 2", text: $pendingPollOptionB)
                    }
                    Section {
                        Button("Todos") {
                            if let data = pendingImageData {
                                let question = pendingQuestion
                                let pollQuestion = pendingPollQuestion
                                let pollOptions = [pendingPollOptionA, pendingPollOptionB]
                                pendingImageData = nil
                                pendingQuestion = ""
                                pendingPollQuestion = ""
                                pendingPollOptionA = ""
                                pendingPollOptionB = ""
                                Task { await viewModel.createStory(imageData: data, visibility: "everyone", questionPrompt: question, pollQuestion: pollQuestion, pollOptions: pollOptions) }
                            }
                        }
                        Button("Mejores amigos") {
                            if let data = pendingImageData {
                                let question = pendingQuestion
                                let pollQuestion = pendingPollQuestion
                                let pollOptions = [pendingPollOptionA, pendingPollOptionB]
                                pendingImageData = nil
                                pendingQuestion = ""
                                pendingPollQuestion = ""
                                pendingPollOptionA = ""
                                pendingPollOptionB = ""
                                Task { await viewModel.createStory(imageData: data, visibility: "close_friends", questionPrompt: question, pollQuestion: pollQuestion, pollOptions: pollOptions) }
                            }
                        }
                    }
                }
                .navigationTitle("¿Quién puede ver esta historia?")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }
}

/// Visor a pantalla completa, avanza a la siguiente historia del mismo
/// autor al tocar, se cierra al llegar al final — mismo patrón simple que
/// Instagram/WhatsApp Status -- antes solo tocar para pasar a mano, sin
/// barra de progreso ni avance automático, comparado con esas apps y con
/// SOCIAL_APP.html (`.stbar`/`.stbarf`). Ahora cada historia tiene su
/// propio segmento de progreso que se rellena en 5s y avanza sola; tocar
/// la mitad derecha adelanta, la izquierda retrocede -- mismo lenguaje de
/// gestos ya estandarizado.
private struct StoryViewer: View {
    let group: StoryGroup
    @ObservedObject var viewModel: StoriesViewModel
    let myID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    // "Quién vio tu historia" (0053_story_views.sql), comparado con
    // Instagram/Snapchat/WhatsApp Status -- antes ni siquiera se
    // registraba quién veía una historia, la tabla no existía.
    @State private var viewers: [StoriesViewModel.StoryViewer] = []
    @State private var showViewers = false
    @State private var progress: CGFloat = 0
    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat.
    @State private var replyText = ""
    // Reacción rápida real a una historia ("toque para reaccionar"),
    // comparado con Instagram/Snapchat -- ver más abajo,
    // 0071_message_story_reply.sql.
    @State private var lastSentReaction: String?
    @FocusState private var isReplyFocused: Bool
    @StateObject private var socialLinks = SocialLinkManager()
    // Adhesivo de pregunta real en una historia ("Pregúntame algo"),
    // comparado con Instagram -- ver
    // StoriesViewModel.respondToQuestion()/loadQuestionResponses(),
    // 0099_story_questions.sql.
    @State private var questionAnswerText = ""
    @State private var questionAnswerSent = false
    @State private var showQuestionResponses = false
    @State private var questionResponses: [StoriesViewModel.StoryQuestionResponse] = []
    // Destacados reales de historias en el perfil, comparado con
    // Instagram -- ver StoriesViewModel.createHighlight(),
    // 0101_story_highlights.sql.
    @State private var showHighlightDialog = false
    @State private var highlightTitleInput = ""
    // Añadir a un destacado YA EXISTENTE, comparado con Instagram -- cierra
    // el hueco deliberado documentado en StoriesViewModel.createHighlight().
    @State private var showNewHighlightInput = false

    private func goNext() {
        if index < group.stories.count - 1 {
            index += 1
        } else {
            dismiss()
        }
    }

    private func goPrevious() {
        if index > 0 { index -= 1 }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let story = group.stories[safe: index] {
                AsyncImage(url: URL(string: story.media_url)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }

                HStack(spacing: 0) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { goPrevious() }
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { goNext() }
                }

                HStack(spacing: 4) {
                    ForEach(group.stories.indices, id: \.self) { i in
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.35))
                                Capsule().fill(Color.white)
                                    .frame(width: geo.size.width * (i < index ? 1 : (i == index ? progress : 0)))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)

                HStack(spacing: 10) {
                    Text(group.authorName)
                        .foregroundStyle(.white)
                    // Silenciar las historias de esta persona sin dejar de
                    // seguirla, comparado con Instagram/Snapchat -- solo
                    // tiene sentido sobre la historia de OTRA persona,
                    // nunca la propia.
                    if story.author_id != myID {
                        Button {
                            Task { await viewModel.toggleMuteAuthor(story.author_id) }
                        } label: {
                            Text(viewModel.mutedAuthorIDs.contains(story.author_id) ? "🔇" : "🔊")
                        }
                    }
                }
                .padding(.top, 24)
                .padding(.horizontal, 16)

                // Encuesta real en una historia, comparado con
                // Instagram/Twitter/X -- ver StoriesViewModel.storyPolls/
                // myPollVotes, 0100_story_polls.sql. Centrada, como un
                // adhesivo real sobre la propia foto (a diferencia de la
                // pregunta/respuesta de más abajo, que van pegadas
                // abajo). Equivalente del bloque de StoriesBar.kt.
                if let poll = viewModel.storyPolls[story.id] {
                    let myVote = viewModel.myPollVotes[poll.id]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(poll.question)
                            .font(.headline)
                            .foregroundStyle(.white)
                        ForEach(Array(poll.options.enumerated()), id: \.offset) { optionIndex, optionText in
                            let votesForOption = poll.vote_counts[safe: optionIndex] ?? 0
                            let totalVotes = poll.vote_counts.reduce(0, +)
                            let percent = totalVotes == 0 ? 0 : (votesForOption * 100) / totalVotes
                            if let myVote {
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.2))
                                    GeometryReader { geo in
                                        Capsule()
                                            .fill(optionIndex == myVote ? Color.accentColor : Color.white.opacity(0.35))
                                            .frame(width: geo.size.width * CGFloat(percent) / 100)
                                    }
                                    Text("\(optionText) · \(percent)%")
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                }
                                .frame(height: 36)
                            } else {
                                Button {
                                    Task { await viewModel.voteOnPoll(pollID: poll.id, optionIndex: optionIndex) }
                                } label: {
                                    Text(optionText)
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .overlay(Capsule().stroke(Color.white, lineWidth: 1))
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                // Adhesivo de pregunta real en una historia ("Pregúntame
                // algo"), comparado con Instagram -- ver
                // StoriesViewModel.storyQuestions, 0099_story_questions.sql.
                let question = viewModel.storyQuestions[story.id]
                if story.author_id == myID {
                    VStack(alignment: .leading, spacing: 6) {
                        Spacer()
                        Button {
                            showViewers = true
                        } label: {
                            Text("👁 \(viewers.count) \(viewers.count == 1 ? "vista" : "vistas")")
                                .foregroundStyle(.white)
                        }
                        // Destacados reales de historias en el perfil,
                        // comparado con Instagram -- solo tiene sentido
                        // sobre tu propia historia, mientras sigue activa.
                        Button {
                            showHighlightDialog = true
                        } label: {
                            Text("⭐ Destacar")
                                .foregroundStyle(.white)
                                .font(.subheadline)
                        }
                        if let question {
                            Button {
                                Task {
                                    questionResponses = await viewModel.loadQuestionResponses(questionID: question.id)
                                    showQuestionResponses = true
                                }
                            } label: {
                                Text("💬 Ver respuestas a: \"\(question.prompt)\"")
                                    .foregroundStyle(.white)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                } else if let question {
                    // Responder en privado a la pregunta real de esta
                    // historia -- a diferencia de "Responder a la
                    // historia" (abajo), esto NO manda un mensaje de chat
                    // normal: solo el autor real la ve, con quién la
                    // escribió.
                    VStack {
                        Spacer()
                        if questionAnswerSent {
                            Text("Respuesta enviada ✓")
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        } else {
                            HStack(spacing: 8) {
                                ZStack(alignment: .leading) {
                                    if questionAnswerText.isEmpty {
                                        Text(question.prompt)
                                            .foregroundStyle(.white.opacity(0.6))
                                    }
                                    TextField("", text: $questionAnswerText)
                                        .foregroundStyle(.white)
                                        .focused($isReplyFocused)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                                if !questionAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        let text = questionAnswerText
                                        Task {
                                            if await viewModel.respondToQuestion(questionID: question.id, text: text) {
                                                questionAnswerSent = true
                                                questionAnswerText = ""
                                            }
                                        }
                                    } label: {
                                        Text("➤").foregroundStyle(.white)
                                    }
                                }
                            }
                            .padding()
                        }
                    }
                } else {
                    // Responder a una historia real
                    // (0071_message_story_reply.sql), comparado con
                    // Instagram/WhatsApp Status/Snapchat -- solo tiene
                    // sentido sobre la historia de OTRA persona, nunca la
                    // propia (para eso ya está "quién vio tu historia").
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer()
                        // Reacción rápida real a una historia ("toque
                        // para reaccionar"), comparado con Instagram/
                        // Snapchat -- distinta de responder con texto
                        // (justo debajo): manda el mismo emoji de un
                        // tirón como un mensaje real, sin pasar por el
                        // campo de texto. Reutiliza tal cual sendReply()
                        // -- ningún esquema nuevo, un emoji es un cuerpo
                        // de mensaje real como cualquier otro.
                        if let lastSentReaction {
                            Text("\(lastSentReaction) enviado")
                                .foregroundStyle(.white)
                                .padding(.horizontal)
                                .padding(.bottom, 6)
                        } else {
                            HStack(spacing: 14) {
                                ForEach(["❤️", "😂", "😮", "😢", "👏", "🔥"], id: \.self) { emoji in
                                    Text(emoji)
                                        .font(.title2)
                                        .onTapGesture {
                                            lastSentReaction = emoji
                                            Task {
                                                guard let myID,
                                                      let chatID = await socialLinks.getOrCreateChat(myID, story.author_id) else { return }
                                                _ = await viewModel.sendReply(chatID: chatID, storyID: story.id, text: emoji)
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        HStack(spacing: 8) {
                            ZStack(alignment: .leading) {
                                if replyText.isEmpty {
                                    Text("Responder a la historia…")
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                TextField("", text: $replyText)
                                    .foregroundStyle(.white)
                                    .focused($isReplyFocused)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Capsule())
                            if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button {
                                    let text = replyText
                                    replyText = ""
                                    Task {
                                        guard let myID,
                                              let chatID = await socialLinks.getOrCreateChat(myID, story.author_id) else { return }
                                        _ = await viewModel.sendReply(chatID: chatID, storyID: story.id, text: text)
                                    }
                                } label: {
                                    Text("➤").foregroundStyle(.white)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        // Reacción rápida real a una historia -- misma forma real de
        // cerrar el aviso "enviado" que el resto de este archivo
        // (`.onChange(of:)` de un parámetro, deployment target iOS 16).
        .onChange(of: lastSentReaction) { newValue in
            guard newValue != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                lastSentReaction = nil
            }
        }
        .task(id: index) {
            showViewers = false
            showQuestionResponses = false
            questionAnswerSent = false
            questionAnswerText = ""
            guard let story = group.stories[safe: index] else { return }
            if story.author_id == myID {
                viewers = await viewModel.loadViewers(storyID: story.id)
            } else {
                await viewModel.recordView(story)
            }
        }
        // 5s por historia, mismo orden de magnitud que Instagram/WhatsApp
        // Status (SOCIAL_APP.html usaba 4s para su maqueta estática). Si
        // el usuario avanza a mano antes de que termine, `.task(id:)`
        // cancela esta tarea al cambiar `index` -- no se dispara un
        // avance doble. Hallazgo real, comparado con Instagram/WhatsApp
        // Status/Snapchat: las tres apps PAUSAN el avance automático
        // mientras se escribe una respuesta -- un avance por pasos de
        // 50ms (en vez de un solo `withAnimation` de 5s) deja comprobar
        // `isReplyFocused` en cada paso y simplemente no acumular tiempo
        // mientras el teclado está activo, mismo criterio que
        // StoriesBar.kt (Android).
        .task(id: index) {
            progress = 0
            let totalMs = 5000
            let stepMs = 50
            var elapsedMs = 0
            while elapsedMs < totalMs {
                try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
                if Task.isCancelled { return }
                if !isReplyFocused {
                    elapsedMs += stepMs
                    withAnimation(.linear(duration: 0.05)) { progress = min(1, CGFloat(elapsedMs) / CGFloat(totalMs)) }
                }
            }
            if !Task.isCancelled { goNext() }
        }
        .sheet(isPresented: $showViewers) {
            NavigationStack {
                List(viewers) { viewer in
                    Text(viewer.displayName)
                }
                .overlay {
                    if viewers.isEmpty {
                        Text("Todavía nadie ha visto esta historia.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Vistas")
            }
        }
        // Adhesivo de pregunta real en una historia ("Pregúntame algo"),
        // comparado con Instagram -- respuestas privadas, solo el propio
        // autor las ve, con quién las escribió. Ver
        // StoriesViewModel.loadQuestionResponses(), 0099_story_questions.sql.
        .sheet(isPresented: $showQuestionResponses) {
            NavigationStack {
                List(questionResponses) { response in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(response.responderName).font(.subheadline.bold())
                        Text(response.body)
                    }
                }
                .overlay {
                    if questionResponses.isEmpty {
                        Text("Todavía nadie ha respondido.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Respuestas")
            }
        }
        // Destacados reales de historias en el perfil, comparado con
        // Instagram -- ofrece añadir a uno YA EXISTENTE (cierra el hueco
        // deliberado documentado en StoriesViewModel.createHighlight()) o
        // crear uno nuevo, mismo diálogo real.
        .sheet(isPresented: Binding(
            get: { showHighlightDialog },
            set: { isPresented in
                showHighlightDialog = isPresented
                if !isPresented { highlightTitleInput = ""; showNewHighlightInput = false }
            }
        )) {
            NavigationStack {
                Group {
                    if showNewHighlightInput {
                        Form {
                            TextField("Título (p. ej. \"Viajes\")", text: $highlightTitleInput)
                        }
                    } else {
                        List {
                            if viewModel.myHighlights.isEmpty {
                                Text("Todavía no tienes ningún destacado.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(viewModel.myHighlights) { highlight in
                                Button(highlight.title) {
                                    if let story = group.stories[safe: index] {
                                        Task { await viewModel.addStoryToHighlight(highlightID: highlight.id, storyID: story.id) }
                                    }
                                    showHighlightDialog = false
                                }
                            }
                            Button("+ Crear nuevo") { showNewHighlightInput = true }
                        }
                    }
                }
                .navigationTitle(showNewHighlightInput ? "Nuevo destacado" : "Añadir a destacado")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { showHighlightDialog = false }
                    }
                    if showNewHighlightInput {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Crear") {
                                if let story = group.stories[safe: index], !highlightTitleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    let title = highlightTitleInput
                                    Task { await viewModel.createHighlight(storyID: story.id, title: title) }
                                }
                                showHighlightDialog = false
                            }
                            .disabled(highlightTitleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .presentationDetents([.height(280)])
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
