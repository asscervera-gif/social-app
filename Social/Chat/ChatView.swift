//
//  ChatView.swift
//  Social
//
//  Chat + barra de compatibilidad con botones +1/+10/+100 y -1/-10/-100,
//  y tarjeta de actividad sugerida cuando la compatibilidad supera 50%.
//

import SwiftUI
import PhotosUI
import AVFoundation

struct ChatView: View {

    @StateObject private var viewModel: ChatViewModel
    let currentUserID: UUID

    init(chatID: UUID, currentUserID: UUID) {
        self._viewModel = StateObject(wrappedValue: ChatViewModel(chatID: chatID, currentUserID: currentUserID))
        self.currentUserID = currentUserID
    }

    @State private var showDuel = false
    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp: no había
    // ninguna forma de denunciar o bloquear a la otra persona DESDE el
    // propio chat -- justo donde ocurre la mayoría del acoso real, según
    // cualquier app de mensajería grande. ReportSheet ya existe y ya
    // incluye ambas acciones, solo faltaba este punto de entrada.
    @State private var showReportSheet = false
    // Hallazgo real, comparado con Instagram/WhatsApp/Messenger: no había
    // forma de denunciar un MENSAJE concreto, solo a la otra persona en
    // general -- ver 0048_reports_message_reference.sql.
    @State private var reportMessageID: UUID?
    // Hallazgo real, comparado con WhatsApp/Telegram/Messenger: mantener
    // pulsado un mensaje propio lo borraba al instante, SIN confirmación
    // -- y no había ninguna forma de corregirlo, solo de borrarlo entero.
    // Ahora mantener pulsado abre un menú real (Editar/Borrar/Cancelar) en
    // vez de un borrado directo -- ver 0049_messages_edit.sql.
    @State private var managingMessage: ChatMessage?
    @State private var editingMessage: ChatMessage?
    @State private var editedMessageText = ""

    var body: some View {
        VStack(spacing: 0) {
            compatibilityBar

            if let activity = viewModel.suggestedActivity {
                ActivityBanner(text: activity)
            }

            // Antes DuelView no tenía ningún punto de entrada real en la
            // app — este es el sitio natural: retar a duelo a la persona
            // con la que ya se está chateando.
            if let opponentID = viewModel.opponentID {
                Button("⚡ Retar a duelo") { showDuel = true }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .sheet(isPresented: $showDuel) {
                        DuelEntryPoint(chatID: viewModel.chatID, currentUserID: currentUserID, opponentID: opponentID)
                    }
                    .sheet(isPresented: $showReportSheet) {
                        ReportSheet(userID: currentUserID, reportedID: opponentID)
                    }
                    // Hallazgo real, comparado con Instagram/WhatsApp/
                    // Messenger: no había forma de denunciar un MENSAJE
                    // concreto, solo a la otra persona en general -- ver
                    // 0048_reports_message_reference.sql. `Binding(get:set:)`
                    // en vez de `.sheet(item:)`: mismo patrón ya usado en
                    // el resto de la sesión para un UUID? sin Identifiable.
                    .sheet(isPresented: Binding(
                        get: { reportMessageID != nil },
                        set: { if !$0 { reportMessageID = nil } }
                    )) {
                        ReportSheet(userID: currentUserID, reportedID: opponentID, messageID: reportMessageID)
                    }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Hueco real: sin esto, un chat con más de 100
                        // mensajes perdía silenciosamente todo lo anterior a
                        // los últimos 100, sin forma de volver a verlo (ver
                        // ChatViewModel.loadOlderMessages()).
                        if viewModel.hasMoreHistory {
                            if viewModel.isLoadingOlder {
                                ProgressView()
                                    .padding(.vertical, 8)
                            } else {
                                Button("Cargar mensajes anteriores") {
                                    Task { await viewModel.loadOlderMessages() }
                                }
                                .buttonStyle(.bordered)
                                .padding(.vertical, 4)
                            }
                        }
                        ForEach(viewModel.messages) { message in
                            MessageBubble(
                                message: message,
                                isMine: message.senderID == currentUserID,
                                currentUserID: currentUserID,
                                reactions: viewModel.reactions[message.id] ?? [],
                                sharedPost: message.sharedPostID.flatMap { viewModel.sharedPosts[$0] },
                                sharedPostAuthor: message.sharedPostID
                                    .flatMap { viewModel.sharedPosts[$0] }
                                    .flatMap { viewModel.sharedPostAuthors[$0.authorID] },
                                storyPreview: message.storyID.flatMap { viewModel.storyPreviews[$0] },
                                onToggleReaction: { emoji in
                                    Task { await viewModel.toggleReaction(messageID: message.id, emoji: emoji) }
                                },
                                onManage: {
                                    managingMessage = message
                                },
                                onReport: {
                                    reportMessageID = message.id
                                }
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                // Closure de un parámetro (newValue), no cero: el deployment
                // target real de este proyecto es iOS 16 (ver project.yml),
                // y la forma sin parámetros de onChange(of:) es exclusiva de
                // iOS 17+ — encontrado al revisar el mismo problema en el
                // onChange recién añadido en RootTabView.swift.
                .onChange(of: viewModel.messages.count) { _ in
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if viewModel.isOpponentTyping {
                Text("Escribiendo…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            // "Potenciar la IA" (petición explícita del usuario), mismo
            // criterio que Hinge/Bumble: sugerencia real para arrancar la
            // conversación en un chat nuevo — nunca se envía sola, solo
            // rellena el campo.
            if let icebreaker = viewModel.icebreaker {
                HStack {
                    Text("✨").padding(.trailing, 4)
                    Text(icebreaker)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("✕") { viewModel.dismissIcebreaker() }
                }
                .padding(.horizontal)
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.draft = icebreaker
                    viewModel.dismissIcebreaker()
                }
            }

            composer
        }
        .navigationTitle("Chat")
        .task { await viewModel.start() }
        .onDisappear { Task { await viewModel.stop() } }
        // Hallazgo real, comparado con WhatsApp/Telegram/Messenger:
        // mantener pulsado un mensaje propio lo borraba al instante, sin
        // confirmación -- ahora un menú real con Editar/Borrar/Cancelar,
        // ver 0049_messages_edit.sql.
        .confirmationDialog(
            "Mensaje",
            isPresented: Binding(
                get: { managingMessage != nil },
                set: { if !$0 { managingMessage = nil } }
            ),
            titleVisibility: .hidden
        ) {
            if let managingMessage {
                Button("Editar") {
                    editingMessage = managingMessage
                    editedMessageText = managingMessage.body ?? ""
                }
                Button("Borrar", role: .destructive) {
                    Task { await viewModel.deleteMessage(managingMessage.id) }
                }
                Button("Cancelar", role: .cancel) {}
            }
        }
        .sheet(item: $editingMessage) { message in
            NavigationStack {
                Form {
                    TextField("Mensaje", text: $editedMessageText, axis: .vertical)
                    Text("\(editedMessageText.count)/2000")
                        .font(.caption2)
                        .foregroundStyle(editedMessageText.count > 2000 ? .red : .secondary)
                }
                .navigationTitle("Editar mensaje")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Guardar") {
                            Task {
                                await viewModel.editMessage(message.id, newBody: editedMessageText)
                                editingMessage = nil
                            }
                        }
                        .disabled(editedMessageText.isEmpty || editedMessageText.count > 2000)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { editingMessage = nil }
                    }
                }
            }
        }
    }

    private var compatibilityBar: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.gray.opacity(0.15))
                    Capsule()
                        .fill(
                            LinearGradient(colors: [.pink, .purple, .orange], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * CGFloat(viewModel.compatibilityScore) / 100)
                        .animation(.spring(duration: 0.4), value: viewModel.compatibilityScore)
                }
            }
            .frame(height: 14)

            HStack {
                Spacer()
                Text("\(viewModel.compatibilityScore)% de compatibilidad")
                    .font(.caption.bold())
                Spacer()
                Button {
                    showReportSheet = true
                } label: {
                    Image(systemName: "exclamationmark.shield")
                }
                .tint(.red)
            }

            if viewModel.isOpponentOnline {
                Text("🟢 En línea")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                voteButton(-100); voteButton(-10); voteButton(-1)
                Spacer()
                voteButton(1); voteButton(10); voteButton(100)
            }
        }
        .padding()
    }

    private func voteButton(_ delta: Int) -> some View {
        Button("\(delta > 0 ? "+" : "")\(delta)") {
            Task { await viewModel.vote(delta: delta) }
        }
        .font(.caption.bold())
        .buttonStyle(.bordered)
        .tint(delta > 0 ? .green : .red)
    }

    @State private var selectedPhoto: PhotosPickerItem?
    // Última pieza real de "chat funcional con fotos, voz, reacciones,
    // read receipts" — grabación nativa (ver VoiceRecorder.swift).
    @State private var voiceRecorder = VoiceRecorder()
    @State private var isRecording = false

    private var composer: some View {
        HStack {
            // Hallazgo real: el chat solo soportaba texto — ver
            // 0016_message_media.sql / ChatViewModel.sendPhoto.
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "camera")
            }
            .onChange(of: selectedPhoto) { newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        await viewModel.sendPhoto(imageData: data)
                    }
                }
            }
            Button {
                if isRecording {
                    isRecording = false
                    if let url = voiceRecorder.stop() {
                        Task { await viewModel.sendVoiceNote(fileURL: url) }
                    }
                } else {
                    if (try? voiceRecorder.start()) != nil {
                        isRecording = true
                    }
                }
            } label: {
                Image(systemName: isRecording ? "stop.circle.fill" : "mic")
                    .foregroundStyle(isRecording ? .red : .primary)
            }
            TextField(isRecording ? "Grabando…" : "Escribe un mensaje…", text: $viewModel.draft)
                .textFieldStyle(.roundedBorder)
                // Mismo closure de un parámetro (newValue) que el resto de
                // onChange(of:) de este archivo — deployment target iOS 16.
                .onChange(of: viewModel.draft) { _ in viewModel.notifyTyping() }
                .disabled(isRecording)
            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(isRecording)
        }
        .padding()
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let isMine: Bool
    let currentUserID: UUID
    let reactions: [ChatViewModel.MessageReaction]
    // Enviar una publicación a un chat real (0069_message_shared_post.sql),
    // comparado con Instagram/TikTok/Twitter/Snapchat.
    var sharedPost: Post? = nil
    var sharedPostAuthor: Profile? = nil
    // Responder a una historia real (0071_message_story_reply.sql),
    // comparado con Instagram/WhatsApp Status/Snapchat.
    var storyPreview: ChatViewModel.StoryPreview? = nil
    let onToggleReaction: (String) -> Void
    // Hallazgo real, comparado con WhatsApp/Telegram/Messenger: mantener
    // pulsado un mensaje propio borraba al instante sin confirmación --
    // ahora abre un menú real (Editar/Borrar/Cancelar), ver
    // 0049_messages_edit.sql.
    var onManage: () -> Void = {}
    // Hallazgo real, comparado con Instagram/WhatsApp/Messenger: no había
    // forma de denunciar un MENSAJE concreto -- ver
    // 0048_reports_message_reference.sql.
    var onReport: () -> Void = {}

    @State private var showPicker = false
    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp: no había
    // forma de tocar una foto del chat para verla a tamaño completo, solo
    // la miniatura recortada de 200pt.
    @State private var fullScreenURL: URL?
    private let reactionEmojis = ["❤", "😂", "😮", "😢", "👍"]

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            HStack {
                if isMine { Spacer() }
                Group {
                    // Enviar una publicación a un chat real
                    // (0069_message_shared_post.sql), comparado con
                    // Instagram/TikTok/Twitter/Snapchat -- toque en
                    // cualquier parte de la vista previa abre la
                    // publicación completa real (PostDetailView.swift),
                    // mismo criterio que Instagram/Messenger: antes solo
                    // abría la foto a tamaño completo.
                    if message.storyID != nil {
                        // Responder a una historia real
                        // (0071_message_story_reply.sql), comparado con
                        // Instagram/WhatsApp Status/Snapchat --
                        // "Historia ya no disponible" si expiró/se borró
                        // (stories_select filtra expires_at,
                        // comportamiento correcto, no un fallo).
                        VStack(alignment: .leading, spacing: 4) {
                            if let mediaURLString = storyPreview?.media_url, let url = URL(string: mediaURLString) {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            Text(isMine ? "Respondiste a una historia" : "Respondió a tu historia")
                                .font(.caption2)
                            if storyPreview == nil {
                                Text("Historia ya no disponible").font(.caption2)
                            }
                            if let body = message.body {
                                Text(body).font(.footnote)
                            }
                        }
                        .padding(8)
                    } else if let sharedPostID = message.sharedPostID {
                        NavigationLink {
                            PostDetailView(postID: sharedPostID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let mediaURLString = sharedPost?.mediaURL, let url = URL(string: mediaURLString) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .frame(width: 200, height: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                Text("Publicación de \(sharedPostAuthor?.displayName ?? "…")")
                                    .font(.caption2)
                                if let caption = sharedPost?.caption {
                                    Text(caption).font(.footnote)
                                }
                            }
                            .padding(8)
                        }
                        .buttonStyle(.plain)
                    } else if let mediaURL = message.mediaURL, let url = URL(string: mediaURL) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        // Toque propio (más específico que el de la
                        // burbuja de abajo): abre la foto a tamaño
                        // completo en vez de alternar el selector de
                        // reacciones.
                        .onTapGesture { fullScreenURL = url }
                    } else if let audioURL = message.audioURL, let url = URL(string: audioURL) {
                        // Última pieza real de "chat funcional" — nota de
                        // voz, reproducción con AVAudioPlayer nativo.
                        AudioMessageBubble(url: url, isMine: isMine)
                    } else {
                        Text(message.body ?? "")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isMine ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.15))
                            .foregroundStyle(isMine ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                // Hallazgo real: última pieza de "chat funcional con
                // fotos, voz, reacciones, read receipts" alcanzable sin
                // infraestructura nueva — ver 0018_message_reactions.sql.
                // Toque en la burbuja abre/cierra un selector rápido.
                .onTapGesture { showPicker.toggle() }
                // Hallazgo real: no había forma de borrar un mensaje propio
                // — mantener pulsado el tuyo lo borra (ver
                // 0022_messages_delete.sql).
                .onLongPressGesture {
                    if isMine { onManage() } else { onReport() }
                }
                if !isMine { Spacer() }
            }
            if !reactions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(Dictionary(grouping: reactions, by: { $0.emoji })), id: \.key) { emoji, group in
                        let iReacted = group.contains { $0.user_id == currentUserID }
                        Text("\(emoji) \(group.count)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(iReacted ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
                            .clipShape(Capsule())
                            .onTapGesture { onToggleReaction(emoji) }
                    }
                }
            }
            if showPicker {
                HStack(spacing: 6) {
                    ForEach(reactionEmojis, id: \.self) { emoji in
                        Text(emoji).onTapGesture {
                            onToggleReaction(emoji)
                            showPicker = false
                        }
                    }
                }
            }
            // Hallazgo real, comparado con WhatsApp/Telegram/Messenger:
            // mismo aviso visual que esas apps cuando un mensaje se
            // corrigió después de enviarse -- ver 0049_messages_edit.sql.
            if message.editedAt != nil {
                Text("Editado")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if isMine {
                Text(message.readAt != nil ? "Leído ✓✓" : "Enviado ✓")
                    .font(.caption2)
                    .foregroundStyle(message.readAt != nil ? Color.accentColor : .secondary)
            }
        }
        // Mismo patrón Binding(get:set:) ya usado en HomeView.swift para
        // un URL? no Identifiable.
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenURL != nil },
            set: { isPresented in if !isPresented { fullScreenURL = nil } }
        )) {
            if let fullScreenURL {
                FullScreenImageView(url: fullScreenURL, onDismiss: { self.fullScreenURL = nil })
            }
        }
    }
}

/// Reproductor de nota de voz — `AVAudioPlayer` nativo, sin SDK de
/// terceros, mismo criterio que `VoiceRecorder`. Equivalente de
/// AudioMessageBubble en ChatScreen.kt.
private struct AudioMessageBubble: View {
    let url: URL
    let isMine: Bool

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            Text("Nota de voz")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isMine ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.15))
        .foregroundStyle(isMine ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            if isPlaying {
                player?.pause()
                isPlaying = false
            } else {
                if player == nil {
                    // La nota de voz se sube a un bucket público — se
                    // reproduce directamente desde la URL remota, sin
                    // descargar a disco primero (mismo criterio que
                    // AsyncImage con las fotos del chat).
                    Task {
                        if let data = try? Data(contentsOf: url) {
                            player = try? AVAudioPlayer(data: data)
                        }
                        player?.play()
                        isPlaying = true
                    }
                } else {
                    player?.play()
                    isPlaying = true
                }
            }
        }
    }
}

private struct ActivityBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
            Text(text).font(.subheadline)
            Spacer()
        }
        .padding(12)
        .background(.yellow.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
