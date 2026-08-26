//
//  GroupChatView.swift
//  Social
//
//  Hilo de un chat de grupo real, comparado con WhatsApp/Instagram/
//  Messenger/Facebook -- ver GroupChatViewModel.swift para el hallazgo
//  completo. Mismo patrón visual que ChatView.swift (1:1). Reacciones
//  reales (0060_group_message_reactions.sql) -- voz/read-receipts siguen
//  pendientes, hueco real documentado. Equivalente de GroupChatScreen.kt.
//

import SwiftUI

struct GroupChatView: View {
    @StateObject private var viewModel: GroupChatViewModel
    let groupName: String
    @State private var draft = ""
    @State private var showMembers = false
    @State private var myID: UUID?
    @Environment(\.dismiss) private var dismiss

    init(groupChatID: UUID, groupName: String) {
        self._viewModel = StateObject(wrappedValue: GroupChatViewModel(groupChatID: groupChatID))
        self.groupName = groupName
    }

    var body: some View {
        VStack {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
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
                                onToggleReaction: { emoji in
                                    Task { await viewModel.toggleReaction(groupMessageID: message.id, emoji: emoji) }
                                }
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
            HStack {
                TextField("Mensaje…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("➤") {
                    let text = draft
                    draft = ""
                    Task { await viewModel.sendMessage(text) }
                }
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
            GroupMembersView(viewModel: viewModel) {
                showMembers = false
                Task {
                    if await viewModel.leaveGroup() {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct GroupMembersView: View {
    @ObservedObject var viewModel: GroupChatViewModel
    let onLeave: () -> Void
    @State private var showAddPicker = false
    @StateObject private var socialsViewModel = SocialsListViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Miembros") {
                    ForEach(viewModel.members) { member in
                        HStack {
                            ActiveAvatarProvider.shared.avatarView(config: member.avatarConfig ?? [:], size: 32)
                            Text(member.displayName)
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
    let onToggleReaction: (String) -> Void

    @State private var showPicker = false
    private let reactionEmojis = ["❤", "😂", "😮", "😢", "👍"]

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            if !isMine {
                Text(senderName ?? "…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(message.body ?? "")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMine ? Color.blue.opacity(0.15) : Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { showPicker.toggle() }
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
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}
