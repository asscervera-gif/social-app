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
import UIKit

struct ChatView: View {

    @StateObject private var viewModel: ChatViewModel
    let currentUserID: UUID
    // Videollamada/llamada de voz 1:1 real (0079_calls.sql), comparado
    // con WhatsApp/Messenger/Instagram -- global de RootTabView.swift
    // (una llamada puede llegar en cualquier pestaña), este chat solo la
    // INICIA. Mismo patrón `@EnvironmentObject` ya usado para
    // `SafetyManager`.
    @EnvironmentObject private var callManager: CallManager

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
    // Historial visual real del % de compatibilidad -- el dato ya
    // existía (compatibility_votes, 0032) pero nunca se leía, solo se
    // insertaba. Hueco #1 de la auditoría de sistemas propios de SOCIAL.
    @State private var showCompatibilityHistory = false
    // Buscar en el chat, comparado con WhatsApp/Telegram/Messenger --
    // hueco real, ningún chat construido esta sesión tenía forma de
    // encontrar un mensaje antiguo salvo desplazarse a mano. Alcance
    // deliberado: busca solo entre los mensajes ya cargados en memoria.
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var scrollToMessageID: UUID?
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
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    @State private var forwardingMessage: ChatMessage?

    // Responder a un mensaje concreto (cita) -- precalculado aparte,
    // mismo motivo que MessageBubble.repliedPreviewText más abajo.
    private var replyingToPreviewText: String? {
        guard let replyingTo = viewModel.replyingTo else { return nil }
        if let body = replyingTo.body { return String(body.prefix(80)) }
        if replyingTo.mediaURL != nil { return "📷 Foto" }
        if replyingTo.audioURL != nil { return "🎤 Nota de voz" }
        return "Mensaje"
    }

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
                // Videollamada/llamada de voz 1:1 real (0079_calls.sql),
                // comparado con WhatsApp/Messenger/Instagram --
                // mensajería sin llamada directa desde el propio chat es
                // la excepción hoy, no la norma.
                HStack {
                    Button {
                        callManager.startCall(chatID: viewModel.chatID, calleeID: opponentID, kind: "audio")
                    } label: {
                        Image(systemName: "phone.fill")
                    }
                    Button {
                        callManager.startCall(chatID: viewModel.chatID, calleeID: opponentID, kind: "video")
                    } label: {
                        Image(systemName: "video.fill")
                    }
                }
                .padding(.horizontal)

                Button("⚡ Retar a duelo") { showDuel = true }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                    .sheet(isPresented: $showDuel) {
                        DuelEntryPoint(chatID: viewModel.chatID, currentUserID: currentUserID, opponentID: opponentID)
                    }
                    .sheet(isPresented: $showReportSheet) {
                        ReportSheet(userID: currentUserID, reportedID: opponentID)
                    }
                    .sheet(isPresented: $showCompatibilityHistory) {
                        CompatibilityHistorySheet(entries: viewModel.compatibilityHistory, currentUserID: currentUserID)
                    }
                    .sheet(isPresented: $showSearch) {
                        ChatSearchSheet(messages: viewModel.messages, query: $searchQuery) { messageID in
                            scrollToMessageID = messageID
                            showSearch = false
                        }
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
                    // Reenviar un mensaje real (0072_message_forward.sql),
                    // comparado con WhatsApp/Telegram/Messenger.
                    .sheet(item: $forwardingMessage) { message in
                        ForwardMessageView(
                            messageBody: message.body,
                            mediaURL: message.mediaURL,
                            audioURL: message.audioURL,
                            onDismiss: { forwardingMessage = nil }
                        )
                    }
                    // Foto para ver una vez, comparado con WhatsApp/
                    // Instagram DM/Snapchat -- se pregunta al elegir la
                    // foto. Ver ChatViewModel.sendPhoto(),
                    // 0105_view_once_messages.sql. `.sheet`/`Form` en
                    // vez de `.confirmationDialog`: ese no admite un
                    // `TextField` propio para el pie de foto nuevo
                    // (mismo hallazgo real ya documentado en
                    // 0099_story_questions.sql).
                    .sheet(isPresented: Binding(
                        get: { pendingPhotoData != nil },
                        set: { if !$0 { pendingPhotoData = nil } }
                    )) {
                        NavigationStack {
                            Form {
                                TextField("Añadir un comentario (opcional)", text: $pendingPhotoCaption)
                                Button("🔥 Ver una vez") {
                                    if let data = pendingPhotoData {
                                        pendingPhotoData = nil
                                        let caption = pendingPhotoCaption
                                        pendingPhotoCaption = ""
                                        Task { await viewModel.sendPhoto(imageData: data, viewOnce: true, caption: caption) }
                                    }
                                }
                                Button("Normal") {
                                    if let data = pendingPhotoData {
                                        pendingPhotoData = nil
                                        let caption = pendingPhotoCaption
                                        pendingPhotoCaption = ""
                                        Task { await viewModel.sendPhoto(imageData: data, viewOnce: false, caption: caption) }
                                    }
                                }
                                Button("Cancelar", role: .cancel) {
                                    pendingPhotoData = nil
                                    pendingPhotoCaption = ""
                                }
                            }
                            .navigationTitle("Enviar foto")
                        }
                    }
            }

            // Fijar un mensaje real (propio o ajeno) para que aparezca
            // destacado arriba del chat, VISIBLE PARA TODOS los
            // participantes -- a diferencia de starred_messages
            // (totalmente privado), comparado con WhatsApp/Telegram, ver
            // 0089_pin_message.sql.
            if let pinnedMessage = viewModel.messages.first(where: { $0.pinnedAt != nil }) {
                HStack {
                    Text("📌")
                    Text(pinnedMessage.body ?? (pinnedMessage.mediaURL != nil ? "📷 Foto" : pinnedMessage.audioURL != nil ? "🎤 Nota de voz" : "Mensaje fijado"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        Task { await viewModel.togglePin(pinnedMessage) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0)
                        .onChange(of: scrollToMessageID) { newValue in
                            if let id = newValue {
                                withAnimation { proxy.scrollTo(id, anchor: .center) }
                                scrollToMessageID = nil
                            }
                        }
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
                        // "Eliminar para mí" real, comparado con
                        // WhatsApp -- resuelto en cliente (mismo
                        // criterio que muted_feed_keywords, 0116). Ver
                        // ChatViewModel.deleteForMe(),
                        // 0118_delete_message_for_me.sql.
                        ForEach(viewModel.messages.filter { !$0.deletedFor.contains(currentUserID) }) { message in
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
                                repliedMessage: message.replyToMessageID.flatMap { repliedID in
                                    viewModel.messages.first { $0.id == repliedID }
                                },
                                onToggleReaction: { emoji in
                                    Task { await viewModel.toggleReaction(messageID: message.id, emoji: emoji) }
                                },
                                onManage: {
                                    managingMessage = message
                                },
                                onForward: {
                                    forwardingMessage = message
                                },
                                onReply: {
                                    viewModel.replyingTo = message
                                },
                                onOpenViewOnce: {
                                    await viewModel.openViewOnceMessage(message.id)
                                },
                                showReadReceipts: viewModel.showReadReceipts
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
                // Mensajes destacados reales, comparado con WhatsApp --
                // sobre CUALQUIER mensaje (propio o ajeno), ver
                // ChatViewModel.toggleStar(), 0087_starred_messages.sql.
                // Mismo menú real, ahora también abierto al mantener
                // pulsado un mensaje AJENO (antes iba directo a denunciar
                // sin dejar destacarlo).
                if managingMessage.senderID == currentUserID {
                    Button("Editar") {
                        editingMessage = managingMessage
                        editedMessageText = managingMessage.body ?? ""
                    }
                } else {
                    Button("Denunciar") {
                        reportMessageID = managingMessage.id
                    }
                }
                // Responder a un mensaje concreto (cita), comparado con
                // WhatsApp/Telegram/iMessage/Instagram DM -- sobre
                // CUALQUIER mensaje (propio o ajeno), ver
                // ChatViewModel.replyingTo, 0102_message_reply.sql.
                Button("Responder") {
                    viewModel.replyingTo = managingMessage
                }
                // Copiar texto, comparado con WhatsApp/Telegram/
                // Messenger -- hueco real, básico y universal.
                if let body = managingMessage.body {
                    Button("Copiar") {
                        UIPasteboard.general.string = body
                    }
                }
                // Fijar un mensaje real (propio o ajeno), VISIBLE PARA
                // TODOS los participantes -- a diferencia de "Destacar"
                // (abajo), totalmente privado. Ver
                // ChatViewModel.togglePin(), 0089_pin_message.sql.
                Button(managingMessage.pinnedAt != nil ? "Desfijar mensaje" : "Fijar mensaje") {
                    Task { await viewModel.togglePin(managingMessage) }
                }
                Button(viewModel.starredMessageIDs.contains(managingMessage.id) ? "Quitar destacado" : "Destacar") {
                    Task { await viewModel.toggleStar(managingMessage.id) }
                }
                // "Eliminar para mí" real, comparado con WhatsApp --
                // sobre CUALQUIER mensaje (propio o ajeno): la otra
                // persona lo sigue viendo con normalidad. Distinto de
                // "Borrar" (abajo, solo el propio remitente), que sí lo
                // borra de verdad para las dos personas. Ver
                // ChatViewModel.deleteForMe(), 0118_delete_message_for_me.sql.
                Button("Eliminar para mí") {
                    Task { await viewModel.deleteForMe(managingMessage.id) }
                }
                if managingMessage.senderID == currentUserID {
                    Button("Borrar para todos", role: .destructive) {
                        Task { await viewModel.deleteMessage(managingMessage.id) }
                    }
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
                Text("\(viewModel.compatibilityScore)% de compatibilidad · ver historial")
                    .font(.caption.bold())
                    .onTapGesture {
                        Task { await viewModel.loadCompatibilityHistory() }
                        showCompatibilityHistory = true
                    }
                Spacer()
                Button {
                    showReportSheet = true
                } label: {
                    Image(systemName: "exclamationmark.shield")
                }
                .tint(.red)
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                // Mensajes que desaparecen real para todo el chat,
                // comparado con WhatsApp/Instagram DM -- ver
                // ChatViewModel.setDisappearingSeconds(),
                // 0115_disappearing_messages.sql.
                Menu {
                    Button("Desactivado") { Task { await viewModel.setDisappearingSeconds(nil) } }
                    Button("24 horas") { Task { await viewModel.setDisappearingSeconds(86400) } }
                    Button("7 días") { Task { await viewModel.setDisappearingSeconds(604800) } }
                    Button("90 días") { Task { await viewModel.setDisappearingSeconds(7776000) } }
                } label: {
                    Text(viewModel.disappearingSeconds != nil ? "🔥" : "🕐")
                }
            }

            if let seconds = viewModel.disappearingSeconds {
                let label = seconds == 86400 ? "24 horas" : (seconds == 604800 ? "7 días" : "90 días")
                Text("🔥 Los mensajes nuevos desaparecen a las \(label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isOpponentOnline {
                Text("🟢 En línea")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let lastActive = viewModel.opponentLastActiveAt {
                // "Últ. vez hace...", comparado con WhatsApp -- alcance
                // deliberado, sin interruptor de privacidad recíproco
                // todavía. Ver ChatViewModel.loadOpponentLastActive(),
                // 0119_last_active_at.sql.
                Text("Últ. vez \(relativeTime(lastActive))")
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
    // Foto para ver una vez, comparado con WhatsApp/Instagram DM/
    // Snapchat -- ver ChatViewModel.sendPhoto(), 0105_view_once_messages.sql.
    @State private var pendingPhotoData: Data?
    // Añadir un pie de foto real, comparado con WhatsApp/Telegram/
    // Instagram DM -- ver ChatViewModel.sendPhoto().
    @State private var pendingPhotoCaption = ""
    // Última pieza real de "chat funcional con fotos, voz, reacciones,
    // read receipts" — grabación nativa (ver VoiceRecorder.swift).
    @State private var voiceRecorder = VoiceRecorder()
    @State private var isRecording = false
    // Escuchar la nota de voz real antes de mandarla, comparado con
    // WhatsApp/Telegram -- antes se mandaba a ciegas en cuanto se
    // soltaba el botón. Equivalente de ChatScreen.kt.pendingVoiceFile.
    @State private var pendingVoiceURL: URL?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var isPreviewPlaying = false

    private var composer: some View {
        VStack(spacing: 0) {
            // Responder a un mensaje concreto (cita), comparado con
            // WhatsApp/Telegram/iMessage/Instagram DM -- vista previa
            // real de a qué se está respondiendo, encima del compositor,
            // con una forma real de cancelarlo antes de enviar. Ver
            // ChatViewModel.replyingTo, 0102_message_reply.sql.
            if let replyingToPreviewText {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Respondiendo")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Text(replyingToPreviewText)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("✕") { viewModel.replyingTo = nil }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.12))
            }
            messageInputRow
        }
    }

    private var messageInputRow: some View {
        HStack {
            // Hallazgo real: el chat solo soportaba texto — ver
            // 0016_message_media.sql / ChatViewModel.sendPhoto.
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "camera")
            }
            .onChange(of: selectedPhoto) { newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        // Foto para ver una vez, comparado con
                        // WhatsApp/Instagram DM/Snapchat -- se pregunta
                        // al elegir la foto. Ver
                        // ChatViewModel.sendPhoto(), 0105_view_once_messages.sql.
                        pendingPhotoData = data
                    }
                }
            }
            Button {
                if isRecording {
                    isRecording = false
                    if let url = voiceRecorder.stop() {
                        pendingVoiceURL = url
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
            // `.sheet` en vez de `.alert`/`.confirmationDialog`: los dos
            // cierran al primer toque de CUALQUIER botón, y aquí hace
            // falta poder tocar "Escuchar" varias veces sin que se
            // cierre -- mismo hallazgo real ya documentado en
            // 0099_story_questions.sql para el mismo problema con
            // TextField.
            .sheet(isPresented: Binding(
                get: { pendingVoiceURL != nil },
                set: { if !$0 { previewPlayer?.stop(); isPreviewPlaying = false; pendingVoiceURL = nil } }
            )) {
                NavigationStack {
                    VStack(spacing: 16) {
                        Button(isPreviewPlaying ? "⏸ Reproduciendo…" : "▶ Escuchar antes de mandarla") {
                            guard let url = pendingVoiceURL else { return }
                            if isPreviewPlaying {
                                previewPlayer?.pause()
                                isPreviewPlaying = false
                            } else {
                                let player = previewPlayer ?? (try? AVAudioPlayer(contentsOf: url))
                                previewPlayer = player
                                player?.play()
                                isPreviewPlaying = true
                            }
                        }
                        .buttonStyle(.bordered)
                        Button("Enviar") {
                            previewPlayer?.stop()
                            isPreviewPlaying = false
                            if let url = pendingVoiceURL {
                                pendingVoiceURL = nil
                                Task { await viewModel.sendVoiceNote(fileURL: url) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Descartar", role: .destructive) {
                            previewPlayer?.stop()
                            isPreviewPlaying = false
                            pendingVoiceURL = nil
                        }
                    }
                    .padding()
                    .navigationTitle("Nota de voz")
                }
                .presentationDetents([.height(220)])
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
    // Responder a un mensaje concreto (cita), comparado con
    // WhatsApp/Telegram/iMessage/Instagram DM -- resuelto por el llamador
    // (ChatView.body) entre los ya cargados del mismo chat; si es nil
    // (p. ej. quedó fuera de la página cargada, o se borró y quedó en
    // null por `on delete set null`), se omite sin más, sin texto de
    // relleno inventado. Ver 0102_message_reply.sql.
    var repliedMessage: ChatMessage? = nil
    let onToggleReaction: (String) -> Void
    // Hallazgo real, comparado con WhatsApp/Telegram/Messenger: mantener
    // pulsado un mensaje propio borraba al instante sin confirmación --
    // ahora abre un menú real (Editar/Borrar/Cancelar), ver
    // 0049_messages_edit.sql.
    // Denunciar un mensaje concreto (0048_reports_message_reference.sql)
    // y destacarlo (0087_starred_messages.sql) se gestionan ahora desde el
    // mismo menú real de onManage() -- mantener pulsado CUALQUIER mensaje
    // (antes: solo el propio) abre ese menú, ver ChatView.body.
    var onManage: () -> Void = {}
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    var onForward: () -> Void = {}
    // Responder a un mensaje concreto (cita), comparado con
    // WhatsApp/Telegram/iMessage/Instagram DM.
    var onReply: () -> Void = {}
    // Foto para ver una vez, comparado con WhatsApp/Instagram DM/
    // Snapchat -- devuelve la URL real ya resuelta (o nil si falla), ver
    // ChatViewModel.openViewOnceMessage(), 0105_view_once_messages.sql.
    var onOpenViewOnce: () async -> String? = { nil }
    // Recibo de lectura real ("Leído ✓✓"), comparado con WhatsApp/
    // Instagram/Messenger -- ya es false si CUALQUIERA de los dos
    // desactivó el suyo, ver ChatViewModel.loadReadReceiptsVisibility(),
    // 0091_read_receipts_toggle.sql.
    var showReadReceipts: Bool = true

    @State private var showPicker = false
    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp: no había
    // forma de tocar una foto del chat para verla a tamaño completo, solo
    // la miniatura recortada de 200pt.
    @State private var fullScreenURL: URL?
    private let reactionEmojis = ["❤", "😂", "😮", "😢", "👍"]
    // Reaccionar con CUALQUIER emoji, comparado con Telegram/Messenger/
    // Slack -- antes solo existían los 5 fijos. Reutiliza el teclado
    // real del sistema (con su propia tecla de emoji), sin construir un
    // selector propio. Equivalente de ChatScreen.kt.
    @State private var showCustomEmojiEntry = false
    @State private var customEmoji = ""

    // Responder a un mensaje concreto (cita) -- precalculado aparte, no
    // inline dentro del ViewBuilder: mismo motivo real ya documentado
    // esta sesión (ReelsView.swift/StoriesBar.swift) de por qué el
    // compilador de Swift puede tardar demasiado en type-checkear una
    // expresión compleja anidada dentro de un ViewBuilder.
    private var repliedPreviewText: String? {
        guard let repliedMessage else { return nil }
        if let body = repliedMessage.body { return String(body.prefix(80)) }
        if repliedMessage.mediaURL != nil { return "📷 Foto" }
        if repliedMessage.audioURL != nil { return "🎤 Nota de voz" }
        return "Mensaje"
    }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            HStack {
                if isMine { Spacer() }
                Group {
                    VStack(alignment: .leading, spacing: 2) {
                    // Responder a un mensaje concreto (cita), comparado
                    // con WhatsApp/Telegram/iMessage/Instagram DM -- vista
                    // previa pequeña por encima del propio contenido, sin
                    // importar de qué tipo sea (texto/foto/audio).
                    if let repliedPreviewText {
                        Text(repliedPreviewText)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
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
                    } else if message.viewOnce && message.openedAt != nil {
                        // Foto real "para ver una vez" ya consumida,
                        // comparado con WhatsApp/Instagram DM/Snapchat --
                        // el propio servidor ya vació media_url de verdad
                        // (0105_view_once_messages.sql), ni siquiera el
                        // remitente puede volver a verla.
                        Text("🔥 Foto vista")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isMine ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.15))
                            .foregroundStyle(isMine ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else if message.viewOnce, message.mediaURL != nil {
                        // Foto real "para ver una vez" todavía sin abrir
                        // -- el toque real solo tiene efecto para el
                        // destinatario (onOpenViewOnce); el propio
                        // remitente no puede consumir la suya
                        // (protect_message_columns ya lo impide del lado
                        // del servidor).
                        Text(isMine ? "🔥 Enviada para ver una vez" : "🔥 Toca para ver una vez")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(isMine ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.15))
                            .foregroundStyle(isMine ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .onTapGesture {
                                guard !isMine else { return }
                                Task {
                                    if let urlString = await onOpenViewOnce(), let url = URL(string: urlString) {
                                        fullScreenURL = url
                                    }
                                }
                            }
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
                    onManage()
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
                    Text("➕").onTapGesture {
                        customEmoji = ""
                        showCustomEmojiEntry = true
                        showPicker = false
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
            // Reenviar un mensaje real (0072_message_forward.sql),
            // comparado con WhatsApp/Telegram/Messenger -- etiqueta real
            // cuando corresponde, y un tap target siempre visible (no
            // solo con mantener pulsado) para reenviar cualquier mensaje
            // real (propio o ajeno) con contenido real (texto/foto/audio)
            // -- las publicaciones compartidas/respuestas a historias
            // quedan fuera de alcance a propósito.
            if message.isForwarded {
                Text("Reenviado")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if message.body != nil || message.mediaURL != nil || message.audioURL != nil {
                HStack(spacing: 10) {
                    // Responder a un mensaje concreto (cita), comparado
                    // con WhatsApp/Telegram/iMessage/Instagram DM.
                    Button("↩ Responder", action: onReply)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Foto para ver una vez, comparado con WhatsApp/
                    // Instagram DM/Snapchat -- nunca reenviable, igual
                    // que esas apps (todo el punto real es que solo la
                    // vea el destinatario elegido, una sola vez).
                    if !message.viewOnce {
                        Button("↪ Reenviar", action: onForward)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if isMine {
                let showRead = message.readAt != nil && showReadReceipts
                // Entregado real (✓✓ gris), comparado con WhatsApp --
                // estado intermedio, ver 0117_message_delivered_status.sql.
                let showDelivered = message.deliveredAt != nil && showReadReceipts
                let statusText = showRead ? "Leído ✓✓" : (showDelivered ? "Entregado ✓✓" : "Enviado ✓")
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(showRead ? Color.accentColor : .secondary)
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
        .alert("Reaccionar con...", isPresented: $showCustomEmojiEntry) {
            TextField("Escribe un emoji real (usa el teclado 😊)", text: $customEmoji)
            Button("Reaccionar") {
                if !customEmoji.isEmpty { onToggleReaction(customEmoji) }
            }
            Button("Cancelar", role: .cancel) {}
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
    // Velocidad de reproducción real (1x/1.5x/2x), comparado con
    // WhatsApp -- hueco real, básico en cualquier nota de voz grande.
    // Equivalente de ChatScreen.kt.AudioMessageBubble.
    @State private var speed: Float = 1

    var body: some View {
        HStack {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            Text("Nota de voz")
            Text("\(speed == 1 ? "1" : (speed == 1.5 ? "1.5" : "2"))x")
                .onTapGesture {
                    speed = speed == 1 ? 1.5 : (speed == 1.5 ? 2 : 1)
                    player?.rate = speed
                }
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
                        player?.enableRate = true
                        player?.rate = speed
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

/// Historial visual real del % de compatibilidad -- el dato
/// (`compatibility_votes`) y su RLS de lectura ya existían desde 0002,
/// pero ningún cliente lo leyó nunca hasta ahora (solo se insertaba,
/// nunca se consultaba). Hueco #1 de la auditoría de sistemas propios de
/// SOCIAL: la feature de menor coste posible, sin migración nueva. Mismo
/// fix ya construido en la versión Kotlin equivalente.
private struct CompatibilityHistorySheet: View {
    let entries: [ChatViewModel.CompatibilityVoteEntry]
    let currentUserID: UUID

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    Text("Todavía no hay ningún voto real de compatibilidad en este chat.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List(entries) { entry in
                        let quien = entry.voter_id == currentUserID ? "Tú" : "La otra persona"
                        let signo = entry.delta > 0 ? "+" : ""
                        Text("\(quien) votó \(signo)\(entry.delta) · \(relativeTime(entry.created_at))")
                    }
                }
            }
            .navigationTitle("Historial de compatibilidad")
        }
    }
}

private func relativeTime(_ isoTimestamp: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let then = formatter.date(from: isoTimestamp) ?? ISO8601DateFormatter().date(from: isoTimestamp) else {
        return ""
    }
    let seconds = Date().timeIntervalSince(then)
    switch seconds {
    case ..<60: return "ahora"
    case ..<3600: return "hace \(Int(seconds / 60))min"
    case ..<86400: return "hace \(Int(seconds / 3600))h"
    case ..<604800: return "hace \(Int(seconds / 86400))d"
    default: return "hace \(Int(seconds / 604800))sem"
    }
}

/// Buscar en el chat, comparado con WhatsApp/Telegram/Messenger --
/// busca solo entre los mensajes ya cargados en memoria (honesto si el
/// mensaje real está más atrás -- "Cargar anteriores" ya existe para
/// eso). Equivalente del diálogo de búsqueda de ChatScreen.kt.
private struct ChatSearchSheet: View {
    let messages: [ChatMessage]
    @Binding var query: String
    let onSelect: (UUID) -> Void

    private var matches: [ChatMessage] {
        guard !query.isEmpty else { return [] }
        return messages.filter { $0.body?.localizedCaseInsensitiveContains(query) == true }
    }

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Texto a buscar", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                if !query.isEmpty && matches.isEmpty {
                    Text("Sin resultados entre los mensajes ya cargados. Prueba \"Cargar anteriores\" si es un mensaje viejo.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                List(matches) { message in
                    Text(message.body ?? "")
                        .lineLimit(1)
                        .onTapGesture { onSelect(message.id) }
                }
            }
            .navigationTitle("Buscar en el chat")
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
