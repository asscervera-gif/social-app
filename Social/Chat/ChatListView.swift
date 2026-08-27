//
//  ChatListView.swift
//  Social
//
//  Lista de chats — no existía en ninguna plataforma (ver
//  ChatListViewModel para el hallazgo completo). Punto de entrada nuevo
//  desde Perfil. Equivalente de ChatListScreen.kt.
//

import SwiftUI

struct ChatListView: View {
    @StateObject private var viewModel = ChatListViewModel()
    let onOpenChat: (UUID) -> Void
    // Silenciar con una duración real elegida (8 horas / 1 semana /
    // siempre), comparado con WhatsApp/Telegram -- ver
    // ChatListViewModel.muteChatFor(), 0082_mute_until.sql. Un
    // `.swipeActions` solo admite botones simples, no un menú -- se guarda
    // el id de la fila objetivo y se muestra un `.confirmationDialog`
    // aparte, en vez de silenciar directo al deslizar.
    @State private var muteTargetID: UUID?
    // Nota efímera real sobre el propio perfil, comparado con Instagram/
    // Facebook Messenger -- ver ChatListViewModel.setMyNote(),
    // 0110_profile_notes.sql. `.confirmationDialog` no admite un
    // `TextField` propio (mismo hallazgo real ya documentado en
    // 0099_story_questions.sql) -- se usa un `.sheet` con `Form`.
    @State private var showNoteSheet = false
    @State private var noteDraft = ""

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                noteDraft = viewModel.myNote ?? ""
                showNoteSheet = true
            } label: {
                Text(viewModel.myNote.map { "📝 \($0)" } ?? "📝 Escribe una nota (dura 24h)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // "Archivados" real, comparado con WhatsApp/Telegram -- antes
            // "Ocultar conversación" (0044_chats_hide.sql) era un viaje
            // solo de ida, sin ninguna sección real para volver a verlos.
            // Ver ArchivedChatsView.swift/ChatListViewModel.loadArchived().
            NavigationLink {
                ArchivedChatsView(viewModel: viewModel, onOpenChat: onOpenChat)
            } label: {
                Text("🗄 Archivados")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
            }
            if viewModel.chats.isEmpty && !viewModel.isLoading {
                Text("Todavía no tienes ningún chat.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.chats) { entry in
                Button {
                    onOpenChat(entry.chat.id)
                } label: {
                    HStack(spacing: 12) {
                        // Hallazgo real, comparado con WhatsApp/Instagram/
                        // Messenger: la lista solo mostraba el nombre,
                        // nunca el avatar de la otra persona.
                        ActiveAvatarProvider.shared.avatarView(config: entry.otherAvatarConfig ?? [:], size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                // Fijar un chat arriba de la lista,
                                // comparado con WhatsApp/Telegram/
                                // Messenger -- ver 0081_pin_chats.sql.
                                if entry.isPinnedForMe {
                                    Image(systemName: "pin.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.otherName)
                                    .font(entry.hasUnread ? .headline.bold() : .headline)
                                // Hallazgo real, comparado con WhatsApp/
                                // Instagram/Messenger: no había ninguna
                                // forma de silenciar una conversación sin
                                // salir ni bloquear -- ver
                                // 0047_message_notify_mute.sql.
                                if entry.isMutedForMe {
                                    Image(systemName: "bell.slash.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                // Hallazgo real, comparado con WhatsApp/
                                // Instagram/Messenger: "Tus chats" no
                                // distinguía visualmente qué conversaciones
                                // tenían mensajes sin leer, solo el badge
                                // total de la pestaña Avisos.
                                if entry.hasUnread {
                                    Circle().fill(.pink).frame(width: 10, height: 10)
                                }
                            }
                            // Nota efímera real de la otra persona,
                            // comparado con Instagram/Facebook Messenger --
                            // ya filtrada por caducidad de 24h en
                            // ChatListViewModel.
                            if let note = entry.otherNoteText {
                                Text("📝 \(note)")
                                    .font(.subheadline.italic())
                                    .foregroundStyle(.pink)
                                    .lineLimit(1)
                            }
                            Text(entry.lastMessage?.isEmpty == false ? entry.lastMessage! : "Sin mensajes todavía")
                                .font(entry.hasUnread ? .subheadline.bold() : .subheadline)
                                .foregroundStyle(entry.hasUnread ? .primary : .secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                // Hallazgo real, comparado con WhatsApp/Instagram/
                // Messenger: no había ninguna forma de quitar una
                // conversación de la lista.
                .swipeActions {
                    Button("Ocultar", role: .destructive) {
                        viewModel.hideChat(entry)
                    }
                    Button(entry.isMutedForMe ? "Activar" : "Silenciar") {
                        if entry.isMutedForMe {
                            viewModel.unmuteChat(entry)
                        } else {
                            muteTargetID = entry.id
                        }
                    }
                    .tint(.gray)
                    // Fijar un chat arriba de la lista, comparado con
                    // WhatsApp/Telegram/Messenger -- ver
                    // ChatListViewModel.togglePin(), 0081_pin_chats.sql.
                    Button(entry.isPinnedForMe ? "Desfijar" : "Fijar") {
                        viewModel.togglePin(entry)
                    }
                    .tint(.orange)
                    // Marcar como no leído manualmente, comparado con
                    // WhatsApp/Telegram/Messenger -- capa personal por
                    // encima del estado real de lectura, NUNCA toca el
                    // recibo de lectura real que ve la otra persona (ver
                    // ChatListViewModel.toggleMarkUnread(),
                    // 0088_mark_chat_unread.sql).
                    Button(entry.markedUnreadForMe ? "Marcar como leído" : "Marcar como no leído") {
                        viewModel.toggleMarkUnread(entry)
                    }
                    .tint(.blue)
                }
            }
        }
        .navigationTitle("Tus chats")
        .confirmationDialog(
            "Silenciar durante…",
            isPresented: Binding(get: { muteTargetID != nil }, set: { if !$0 { muteTargetID = nil } })
        ) {
            if let entry = viewModel.chats.first(where: { $0.id == muteTargetID }) {
                Button("8 horas") {
                    viewModel.muteChatFor(entry, until: Date().addingTimeInterval(8 * 3600))
                    muteTargetID = nil
                }
                Button("1 semana") {
                    viewModel.muteChatFor(entry, until: Date().addingTimeInterval(7 * 24 * 3600))
                    muteTargetID = nil
                }
                Button("Siempre") {
                    viewModel.muteChatFor(entry, until: nil)
                    muteTargetID = nil
                }
                Button("Cancelar", role: .cancel) { muteTargetID = nil }
            }
        }
        .task {
            await viewModel.start()
        }
        .onDisappear {
            Task { await viewModel.stop() }
        }
        // Hallazgo real: comparado con Instagram/Twitter/Facebook (y con
        // Home/Match, ya con .refreshable), "Tus chats" no tenía
        // pull-to-refresh.
        .refreshable { await viewModel.load() }
        .sheet(isPresented: $showNoteSheet) {
            NavigationStack {
                Form {
                    TextField("¿Qué estás pensando?", text: $noteDraft)
                        .onChange(of: noteDraft) { newValue in
                            if newValue.count > 60 { noteDraft = String(newValue.prefix(60)) }
                        }
                }
                .navigationTitle("Tu nota (dura 24h)")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Guardar") {
                            viewModel.setMyNote(noteDraft)
                            showNoteSheet = false
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { showNoteSheet = false }
                    }
                }
            }
        }
    }
}
