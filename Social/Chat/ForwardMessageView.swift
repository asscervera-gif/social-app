//
//  ForwardMessageView.swift
//  Social
//
//  Reenviar un mensaje real (0072_message_forward.sql), comparado con
//  WhatsApp/Telegram/Messenger: cualquier mensaje (propio o ajeno) se
//  puede mandar a otro chat o grupo -- uno de los gestos de mensajería
//  más usados de esas apps, sin ninguna forma real en SOCIAL hasta esta
//  ronda.
//
//  Mismo selector "Enviar a…" que SendPostView.swift (reutiliza
//  ChatListViewModel/GroupChatsViewModel igual, solo para listar a quién
//  enviar), duplicado en vez de compartido porque cada uno inserta un
//  contenido distinto (shared_post_id vs. body/media_url/audio_url +
//  is_forwarded) -- mismo criterio ya aplicado a GroupAudioMessageBubble.
//  Solo copia texto/foto/audio -- reenviar una publicación compartida o
//  una respuesta a una historia queda fuera de alcance a propósito (esos
//  mensajes no llevan body/media/audio propios, solo una referencia).
//  Equivalente de ForwardMessageSheet.kt.
//

import SwiftUI

struct ForwardMessageView: View {
    // Nombrado `messageBody` (no `body`) a propósito: `body` colisionaría
    // con la propiedad computada `body: some View` que exige `View`.
    let messageBody: String?
    let mediaURL: String?
    let audioURL: String?
    let onDismiss: () -> Void

    @StateObject private var chatListViewModel = ChatListViewModel()
    @StateObject private var groupsViewModel = GroupChatsViewModel()

    private struct NewForwardedMessage: Encodable {
        let chat_id: UUID
        let sender_id: UUID
        let body: String?
        let media_url: String?
        let audio_url: String?
        let is_forwarded = true
    }

    private struct NewForwardedGroupMessage: Encodable {
        let group_chat_id: UUID
        let sender_id: UUID
        let body: String?
        let media_url: String?
        let audio_url: String?
        let is_forwarded = true
    }

    private func sendToChat(_ chatID: UUID) {
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            do {
                try await SupabaseManager.shared.client
                    .from("messages")
                    .insert(NewForwardedMessage(chat_id: chatID, sender_id: userID, body: messageBody, media_url: mediaURL, audio_url: audioURL))
                    .execute()
                onDismiss()
            } catch {
                // Sin bloquear la hoja si falla -- el usuario puede reintentar.
            }
        }
    }

    private func sendToGroup(_ groupChatID: UUID) {
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            do {
                try await SupabaseManager.shared.client
                    .from("group_messages")
                    .insert(NewForwardedGroupMessage(group_chat_id: groupChatID, sender_id: userID, body: messageBody, media_url: mediaURL, audio_url: audioURL))
                    .execute()
                onDismiss()
            } catch {
                // Sin bloquear la hoja si falla -- el usuario puede reintentar.
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if chatListViewModel.chats.isEmpty && groupsViewModel.groups.isEmpty {
                    Text("Todavía no tienes chats ni grupos para reenviar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(chatListViewModel.chats) { entry in
                    Button {
                        sendToChat(entry.chat.id)
                    } label: {
                        HStack {
                            ActiveAvatarProvider.shared.avatarView(config: entry.otherAvatarConfig ?? [:], size: 36)
                            Text(entry.otherName)
                        }
                    }
                }
                ForEach(groupsViewModel.groups) { group in
                    Button {
                        sendToGroup(group.id)
                    } label: {
                        HStack {
                            Text("👥")
                            Text(group.name)
                        }
                    }
                }
            }
            .navigationTitle("Reenviar a…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", action: onDismiss)
                }
            }
            .task {
                await chatListViewModel.load()
                await groupsViewModel.load()
            }
        }
    }
}
