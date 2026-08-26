//
//  GroupChatView.swift
//  Social
//
//  Hilo de un chat de grupo real, comparado con WhatsApp/Instagram/
//  Messenger/Facebook -- ver GroupChatViewModel.swift para el hallazgo
//  completo. Mismo patrón visual que ChatView.swift (1:1), simplificado
//  (sin reacciones/voz/read-receipts todavía, hueco real documentado).
//  Equivalente de GroupChatScreen.kt.
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
                            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                                if !isMine {
                                    Text(sender?.displayName ?? "…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(message.body ?? "")
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isMine ? Color.blue.opacity(0.15) : Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
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
