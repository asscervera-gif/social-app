//
//  StarredMessagesView.swift
//  Social
//
//  Mensajes destacados ("Starred messages"), comparado con WhatsApp --
//  comprobado en el propio código: `grep` de "starred"/"destacad"/
//  "favorit" en todo el repo no encontró nada, el único mecanismo
//  parecido (`saved_posts`, ver SavedPostsView.swift) es para
//  publicaciones, no para mensajes de chat. Mismo patrón exacto: tabla
//  propia, RLS privada, pantalla propia (0087_starred_messages.sql).
//  Equivalente de StarredMessagesScreen.kt.
//
//  Referencia real polimórfica: un destacado viene de `messages` (1:1) O
//  de `group_messages` (grupo), nunca los dos -- se resuelven ambos
//  embeds en una sola consulta real de PostgREST y se aplanan aquí mismo
//  en un solo modelo de UI.
//

import SwiftUI

struct StarredEntry: Identifiable {
    let id: UUID
    let isGroup: Bool
    let chatID: UUID?
    let groupChatID: UUID?
    let senderID: UUID
    let body: String?
    let createdAt: String
}

@MainActor
final class StarredMessagesViewModel: ObservableObject {
    @Published var entries: [StarredEntry] = []
    @Published var errorMessage: String?
    @Published var senderProfiles: [UUID: Profile] = [:]

    private struct MessageEmbed: Decodable {
        let chat_id: UUID
        let sender_id: UUID
        let body: String?
    }

    private struct GroupMessageEmbed: Decodable {
        let group_chat_id: UUID
        let sender_id: UUID
        let body: String?
    }

    private struct StarredRow: Decodable {
        let id: UUID
        let created_at: String
        let messages: MessageEmbed?
        let group_messages: GroupMessageEmbed?
    }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let rows: [StarredRow] = try await SupabaseManager.shared.client
                .from("starred_messages")
                .select("id,created_at,messages(chat_id,sender_id,body),group_messages(group_chat_id,sender_id,body)")
                .eq("user_id", value: userID)
                .order("created_at", ascending: false)
                .execute()
                .value
            entries = rows.compactMap { row in
                if let m = row.messages {
                    return StarredEntry(id: row.id, isGroup: false, chatID: m.chat_id, groupChatID: nil, senderID: m.sender_id, body: m.body, createdAt: row.created_at)
                } else if let g = row.group_messages {
                    return StarredEntry(id: row.id, isGroup: true, chatID: nil, groupChatID: g.group_chat_id, senderID: g.sender_id, body: g.body, createdAt: row.created_at)
                }
                return nil
            }

            let senderIDs = Array(Set(entries.map { $0.senderID }))
            if !senderIDs.isEmpty,
               let profiles: [Profile] = try? await SupabaseManager.shared.client
                   .from("profiles")
                   .select()
                   .in("id", values: senderIDs)
                   .execute()
                   .value {
                senderProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            }
        } catch {
            errorMessage = "No se pudieron cargar tus mensajes destacados."
        }
    }

    /// Quitar de destacados desde esta misma lista -- mismo criterio que
    /// SavedPostsViewModel.unsave(). Equivalente de
    /// StarredMessagesViewModel.kt.unstar().
    func unstar(_ entry: StarredEntry) async {
        entries.removeAll { $0.id == entry.id }
        do {
            try await SupabaseManager.shared.client
                .from("starred_messages")
                .delete()
                .eq("id", value: entry.id)
                .execute()
        } catch {
            errorMessage = "No se pudo quitar el destacado."
        }
    }
}

struct StarredMessagesView: View {
    @StateObject private var viewModel = StarredMessagesViewModel()
    @State private var myID: UUID?
    @State private var selectedChatID: UUID?
    @State private var selectedGroupChatID: UUID?

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if viewModel.entries.isEmpty && viewModel.errorMessage == nil {
                Text("Todavía no has destacado ningún mensaje.").foregroundStyle(.secondary)
            }
            ForEach(viewModel.entries) { entry in
                Button {
                    if entry.isGroup {
                        selectedGroupChatID = entry.groupChatID
                    } else {
                        selectedChatID = entry.chatID
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            ActiveAvatarProvider.shared.avatarView(
                                config: viewModel.senderProfiles[entry.senderID]?.avatarConfig ?? [:],
                                size: 24
                            )
                            Text(viewModel.senderProfiles[entry.senderID]?.displayName ?? "…")
                                .font(.subheadline.bold())
                        }
                        Text(entry.body ?? "").font(.body)
                        HStack {
                            Text(entry.isGroup ? "En un grupo" : "En un chat")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Quitar") {
                                Task { await viewModel.unstar(entry) }
                            }
                            .font(.caption)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Destacados")
        .task {
            await viewModel.load()
            myID = try? await SupabaseManager.shared.client.auth.session.user.id
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedChatID != nil },
            set: { isPresented in if !isPresented { selectedChatID = nil } }
        )) {
            if let selectedChatID, let myID {
                ChatView(chatID: selectedChatID, currentUserID: myID)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedGroupChatID != nil },
            set: { isPresented in if !isPresented { selectedGroupChatID = nil } }
        )) {
            if let selectedGroupChatID {
                GroupChatView(groupChatID: selectedGroupChatID, groupName: "Grupo")
            }
        }
    }
}
