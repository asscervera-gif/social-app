//
//  GroupChatView.swift
//  Social
//
//  Hilo de un chat de grupo real, comparado con WhatsApp/Instagram/
//  Messenger/Facebook -- ver GroupChatViewModel.swift para el hallazgo
//  completo. Mismo patrón visual que ChatView.swift (1:1). Reacciones
//  (0060_group_message_reactions.sql), "visto por"
//  (0061_group_message_reads.sql), notas de voz
//  (0062_group_message_audio.sql) y fotos (media_url, ya en el esquema
//  desde 0057_group_chats.sql) reales. Equivalente de GroupChatScreen.kt.
//

import SwiftUI
import AVFoundation
import PhotosUI

struct GroupChatView: View {
    @StateObject private var viewModel: GroupChatViewModel
    let groupName: String
    @State private var draft = ""
    @State private var showMembers = false
    @State private var myID: UUID?
    @Environment(\.dismiss) private var dismiss
    // Nota de voz real (0062_group_message_audio.sql), mismo patrón
    // exacto que ChatView.swift (1:1).
    @State private var voiceRecorder = VoiceRecorder()
    @State private var isRecording = false
    // Fotos reales en un chat de grupo, comparado con WhatsApp/Instagram/
    // Messenger/Facebook -- mismo patrón exacto que ChatView.swift (1:1).
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var fullScreenURL: URL?
    // Editar/borrar un mensaje ya enviado en un grupo real
    // (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
    // Telegram/Messenger -- mismo menú real que ChatView.swift (chat 1:1).
    @State private var managingMessage: GroupMessage?
    @State private var editingMessage: GroupMessage?
    @State private var editedMessageText = ""
    // Denunciar un mensaje concreto de un chat de grupo real
    // (0067_reports_group_message_reference.sql), comparado con
    // Instagram/WhatsApp/Messenger -- mismo menú real que ChatView.swift
    // (chat 1:1), pero aquí el denunciado es quien ESCRIBIÓ ese mensaje en
    // concreto, no un único "oponente" fijo como en el 1:1.
    @State private var reportMessage: GroupMessage?
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    @State private var forwardingMessage: GroupMessage?

    init(groupChatID: UUID, groupName: String) {
        self._viewModel = StateObject(wrappedValue: GroupChatViewModel(groupChatID: groupChatID))
        self.groupName = groupName
    }

    var body: some View {
        VStack {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            // "En línea" real en un chat de grupo, comparado con
            // WhatsApp/Messenger -- ver GroupChatViewModel.swift para el
            // hallazgo completo. Mismo texto que ChatView.swift (1:1)
            // pero con el conteo, ya que aquí puede haber varios a la vez.
            if !viewModel.onlineMemberIDs.isEmpty {
                Text("🟢 \(viewModel.onlineMemberIDs.count) en línea")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.messages) { message in
                            let sender = viewModel.members.first { $0.id == message.senderID }
                            let isMine = message.senderID == myID
                            GroupMessageBubble(
                                message: message,
                                senderName: sender?.displayName,
                                isMine: isMine,
                                currentUserID: myID,
                                reactions: viewModel.reactions[message.id] ?? [],
                                readCount: (viewModel.reads[message.id] ?? []).filter { $0 != myID }.count,
                                sharedPost: message.sharedPostID.flatMap { viewModel.sharedPosts[$0] },
                                sharedPostAuthor: message.sharedPostID
                                    .flatMap { viewModel.sharedPosts[$0] }
                                    .flatMap { viewModel.sharedPostAuthors[$0.authorID] },
                                onToggleReaction: { emoji in
                                    Task { await viewModel.toggleReaction(groupMessageID: message.id, emoji: emoji) }
                                },
                                onOpenFullScreen: { url in fullScreenURL = url },
                                onManage: { managingMessage = message },
                                onReport: { reportMessage = message },
                                onForward: { forwardingMessage = message }
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: viewModel.messages.count) { _ in
                    if let last = viewModel.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            // "Escribiendo…" real en un chat de grupo, comparado con
            // WhatsApp/Messenger -- resuelve los IDs a nombres usando la
            // lista de miembros ya cargada, y a diferencia del chat 1:1
            // puede haber varias personas escribiendo a la vez.
            let typingNames = viewModel.typingMemberIDs
                .filter { $0 != myID }
                .compactMap { id in viewModel.members.first { $0.id == id }?.displayName }
            if !typingNames.isEmpty {
                Text(typingNames.count == 1
                    ? "\(typingNames[0]) está escribiendo…"
                    : "\(typingNames[0]) y \(typingNames.count - 1) más están escribiendo…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            HStack {
                // Fotos reales en un chat de grupo, comparado con
                // WhatsApp/Instagram/Messenger/Facebook -- mismo patrón
                // exacto que ChatView.swift (1:1).
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
                // Nota de voz real (0062_group_message_audio.sql), mismo
                // patrón exacto que ChatView.swift (1:1).
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
                TextField(isRecording ? "Grabando…" : "Mensaje…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRecording)
                Button("➤") {
                    let text = draft
                    draft = ""
                    Task { await viewModel.sendMessage(text) }
                }
                .disabled(isRecording)
            }
            .padding()
        }
        .navigationTitle(groupName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("👥 \(viewModel.members.count)") { showMembers = true }
            }
        }
        .task {
            await viewModel.load()
            myID = try? await SupabaseManager.shared.client.auth.session.user.id
        }
        .sheet(isPresented: $showMembers) {
            GroupMembersView(viewModel: viewModel, myID: myID) {
                showMembers = false
                Task {
                    if await viewModel.leaveGroup() {
                        dismiss()
                    }
                }
            }
        }
        // Fotos reales en un chat de grupo, comparado con WhatsApp/
        // Instagram/Messenger/Facebook -- mismo patrón Binding(get:set:)
        // ya usado en ChatView.swift (1:1) para un URL? no Identifiable.
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenURL != nil },
            set: { isPresented in if !isPresented { fullScreenURL = nil } }
        )) {
            if let fullScreenURL {
                FullScreenImageView(url: fullScreenURL, onDismiss: { self.fullScreenURL = nil })
            }
        }
        // Denunciar un mensaje concreto de un chat de grupo real
        // (0067_reports_group_message_reference.sql), comparado con
        // Instagram/WhatsApp/Messenger -- mismo patrón Binding(get:set:)
        // ya usado en ChatView.swift (1:1) para un valor sin Identifiable
        // como target completo del sheet.
        .sheet(isPresented: Binding(
            get: { reportMessage != nil },
            set: { if !$0 { reportMessage = nil } }
        )) {
            if let reportMessage, let myID {
                ReportSheet(userID: myID, reportedID: reportMessage.senderID, groupMessageID: reportMessage.id)
            }
        }
        // Reenviar un mensaje real (0072_message_forward.sql), comparado
        // con WhatsApp/Telegram/Messenger.
        .sheet(item: $forwardingMessage) { message in
            ForwardMessageView(
                messageBody: message.body,
                mediaURL: message.mediaURL,
                audioURL: message.audioURL,
                onDismiss: { forwardingMessage = nil }
            )
        }
        // Editar/borrar un mensaje ya enviado en un grupo real
        // (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
        // Telegram/Messenger -- mismo menú real que ChatView.swift (1:1).
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
}

private struct GroupMembersView: View {
    @ObservedObject var viewModel: GroupChatViewModel
    let myID: UUID?
    let onLeave: () -> Void
    @State private var showAddPicker = false
    @StateObject private var socialsViewModel = SocialsListViewModel()
    // Nombre editable y foto de grupo real, comparado con WhatsApp/
    // Messenger/Telegram -- solo el creador puede tocarlos (RLS
    // `group_chats_update_own`, 0057_group_chats.sql, mismo rol de
    // "admin" que esas apps sin construir un sistema de roles nuevo).
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var selectedGroupPhoto: PhotosPickerItem?

    private var isCreator: Bool { viewModel.groupChat?.createdBy != nil && viewModel.groupChat?.createdBy == myID }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        PhotosPicker(selection: $selectedGroupPhoto, matching: .images) {
                            if let photoURLString = viewModel.groupChat?.photoURL, let photoURL = URL(string: photoURLString) {
                                AsyncImage(url: photoURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(Circle())
                            } else {
                                Circle().fill(Color(.systemGray5)).frame(width: 48, height: 48).overlay(Text("👥"))
                            }
                        }
                        .disabled(!isCreator)
                        .onChange(of: selectedGroupPhoto) { newValue in
                            Task {
                                if let data = try? await newValue?.loadTransferable(type: Data.self) {
                                    await viewModel.updatePhoto(imageData: data)
                                }
                            }
                        }
                        if editingName {
                            TextField("Nombre del grupo", text: $nameDraft)
                            Button("Guardar") {
                                Task { await viewModel.renameGroup(nameDraft) }
                                editingName = false
                            }
                        } else {
                            Text(viewModel.groupChat?.name ?? "Grupo").font(.headline)
                            if isCreator {
                                Spacer()
                                Button {
                                    nameDraft = viewModel.groupChat?.name ?? ""
                                    editingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                            }
                        }
                    }
                }
                Section("Miembros") {
                    ForEach(viewModel.members) { member in
                        HStack {
                            ActiveAvatarProvider.shared.avatarView(config: member.avatarConfig ?? [:], size: 32)
                            Text(member.displayName)
                        }
                        // Expulsar a otro miembro real, comparado con
                        // WhatsApp/Messenger/Telegram -- solo el creador lo
                        // ve, y nunca sobre sí mismo (para eso ya está
                        // "Salir del grupo").
                        .swipeActions {
                            if isCreator && member.id != myID {
                                Button("Quitar", role: .destructive) {
                                    Task { await viewModel.kickMember(member.id) }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("+ Añadir a alguien") { showAddPicker = true }
                    if showAddPicker {
                        let memberIDs = Set(viewModel.members.map { $0.id })
                        ForEach(socialsViewModel.socials.filter { !memberIDs.contains($0.id) }) { entry in
                            Button {
                                Task {
                                    await viewModel.addMember(entry.id)
                                    showAddPicker = false
                                }
                            } label: {
                                HStack {
                                    ActiveAvatarProvider.shared.avatarView(config: entry.avatarConfig ?? [:], size: 28)
                                    Text(entry.displayName)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Salir del grupo", role: .destructive, action: onLeave)
                }
            }
            .navigationTitle("Miembros del grupo")
            .task { await socialsViewModel.load() }
        }
    }
}

/// Burbuja de un mensaje de grupo con reacciones reales
/// (0060_group_message_reactions.sql), comparado con WhatsApp/Messenger/
/// Instagram -- mismo patrón exacto que la burbuja del chat 1:1 en
/// ChatView.swift: tocar la burbuja abre/cierra un selector rápido de
/// emojis. Vista propia (no inline en el ForEach) porque `showPicker`
/// necesita ser un `@State` por mensaje.
private struct GroupMessageBubble: View {
    let message: GroupMessage
    let senderName: String?
    let isMine: Bool
    let currentUserID: UUID?
    let reactions: [GroupChatViewModel.GroupMessageReaction]
    let readCount: Int
    // Enviar una publicación a un chat de grupo real
    // (0069_message_shared_post.sql), comparado con Instagram/TikTok/
    // Twitter/Snapchat.
    var sharedPost: Post? = nil
    var sharedPostAuthor: Profile? = nil
    let onToggleReaction: (String) -> Void
    var onOpenFullScreen: (URL) -> Void = { _ in }
    // Editar/borrar un mensaje ya enviado en un grupo real
    // (0065_group_messages_edit_delete.sql), comparado con WhatsApp/
    // Telegram/Messenger -- mismo criterio que MessageBubble
    // (ChatView.swift, chat 1:1): mantener pulsado el propio mensaje.
    var onManage: () -> Void = {}
    var onReport: () -> Void = {}
    // Reenviar un mensaje real (0072_message_forward.sql), comparado con
    // WhatsApp/Telegram/Messenger.
    var onForward: () -> Void = {}

    @State private var showPicker = false
    private let reactionEmojis = ["❤", "😂", "😮", "😢", "👍"]

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            if !isMine {
                Text(senderName ?? "…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Nota de voz real (0062_group_message_audio.sql), comparado
            // con WhatsApp/Messenger/Telegram -- mismo reproductor nativo
            // que ChatView.swift (1:1).
            if let sharedPostID = message.sharedPostID {
                // Enviar una publicación a un chat de grupo real
                // (0069_message_shared_post.sql), comparado con
                // Instagram/TikTok/Twitter/Snapchat -- toque en cualquier
                // parte de la vista previa abre la publicación completa
                // real (PostDetailView.swift), mismo patrón exacto que
                // ChatView.swift (chat 1:1).
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
            } else if let audioURLString = message.audioURL, let audioURL = URL(string: audioURLString) {
                GroupAudioMessageBubble(url: audioURL, isMine: isMine)
                    .onTapGesture { showPicker.toggle() }
            } else if let mediaURLString = message.mediaURL, let mediaURL = URL(string: mediaURLString) {
                // Fotos reales en un chat de grupo, comparado con
                // WhatsApp/Instagram/Messenger/Facebook -- mediaURL ya
                // existía en el esquema (0057_group_chats.sql), solo
                // faltaba la UI.
                AsyncImage(url: mediaURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { onOpenFullScreen(mediaURL) }
            } else {
                Text(message.body ?? "")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMine ? Color.blue.opacity(0.15) : Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { showPicker.toggle() }
                    .onLongPressGesture { if isMine { onManage() } else { onReport() } }
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
            // Editar un mensaje ya enviado en un grupo real
            // (0065_group_messages_edit_delete.sql), comparado con
            // WhatsApp/Telegram/Messenger -- mismo aviso visual que
            // ChatView.swift (chat 1:1).
            if message.editedAt != nil {
                Text("Editado")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Reenviar un mensaje real (0072_message_forward.sql),
            // comparado con WhatsApp/Telegram/Messenger -- mismo patrón
            // exacto que ChatView.swift (chat 1:1).
            if message.isForwarded {
                Text("Reenviado")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if message.body != nil || message.mediaURL != nil || message.audioURL != nil {
                Button("↪ Reenviar", action: onForward)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // "Visto por" real (0061_group_message_reads.sql), comparado
            // con WhatsApp/Messenger -- solo en los propios mensajes,
            // igual que esas apps solo muestran el recibo de lectura de
            // lo que TÚ enviaste.
            if isMine && readCount > 0 {
                Text("Visto por \(readCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

/// Reproductor de nota de voz de grupo -- `AVAudioPlayer` nativo, mismo
/// criterio exacto que `AudioMessageBubble` (ChatView.swift, chat 1:1),
/// duplicado en vez de compartido porque ese `struct` es privado a su
/// propio archivo.
private struct GroupAudioMessageBubble: View {
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
        .background(isMine ? Color.blue.opacity(0.15) : Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            if isPlaying {
                player?.pause()
                isPlaying = false
            } else {
                if player == nil {
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
