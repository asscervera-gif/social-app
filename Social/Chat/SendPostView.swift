//
//  SendPostView.swift
//  Social
//
//  "Enviar a…" real, comparado con Instagram/TikTok/Twitter/Snapchat: en
//  las cuatro apps, el icono ➤ de una publicación abre este selector
//  interno (un chat 1:1, un grupo) -- el mecanismo de distribución más
//  usado de esas apps, más que el "compartir" externo al sistema. Antes,
//  el mismo icono en HomeView.swift solo abría el share sheet nativo de
//  iOS (texto plano hacia otra app), sin ninguna forma de mandar la
//  publicación como mensaje real dentro de la propia app.
//
//  Reutiliza tal cual ChatListViewModel/GroupChatsViewModel (ya
//  construidos para "Tus chats"/"Grupos") solo para listar a quién se
//  puede enviar -- el envío en sí es un insert directo, sin necesitar una
//  instancia completa de ChatViewModel/GroupChatViewModel para un chat
//  concreto. "Compartir externamente" se mantiene como opción secundaria
//  al final, mismo comportamiento que ya existía antes de esta ronda.
//  Equivalente de SendPostSheet.kt.
//

import SwiftUI

struct SendPostView: View {
    let postID: UUID
    // Texto real ya usado por el ShareLink nativo que este selector
    // reemplaza como acción principal -- se conserva como fila normal
    // dentro de la propia lista (ShareLink funciona como cualquier otra
    // fila de SwiftUI, sin necesitar un callback imperativo aparte).
    let shareText: String
    let onDismiss: () -> Void

    @StateObject private var chatListViewModel = ChatListViewModel()
    @StateObject private var groupsViewModel = GroupChatsViewModel()

    private struct NewSharedMessage: Encodable {
        let chat_id: UUID
        let sender_id: UUID
        let shared_post_id: UUID
    }

    private struct NewSharedGroupMessage: Encodable {
        let group_chat_id: UUID
        let sender_id: UUID
        let shared_post_id: UUID
    }

    private func sendToChat(_ chatID: UUID) {
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            do {
                try await SupabaseManager.shared.client
                    .from("messages")
                    .insert(NewSharedMessage(chat_id: chatID, sender_id: userID, shared_post_id: postID))
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
                    .insert(NewSharedGroupMessage(group_chat_id: groupChatID, sender_id: userID, shared_post_id: postID))
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
                    Text("Todavía no tienes chats ni grupos para enviar.")
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
                ShareLink(item: shareText) {
                    Text("Compartir externamente")
                }
            }
            .navigationTitle("Enviar a…")
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
