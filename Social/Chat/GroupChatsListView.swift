//
//  GroupChatsListView.swift
//  Social
//
//  Lista de chats de grupo reales + crear uno propio, comparado con
//  WhatsApp/Instagram/Messenger/Facebook. Ronda de cliente sobre el
//  backend ya construido y verificado (0057_group_chats.sql). Mismo
//  patrón visual que ChatListView.swift (chats 1:1), en una pantalla
//  propia -- no se mezclan las dos listas para no reescribir
//  ChatListView/ViewModel, que ya funcionan bien para 1:1. Equivalente de
//  GroupChatsListScreen.kt.
//

import SwiftUI

struct GroupChatsListView: View {
    @StateObject private var viewModel = GroupChatsViewModel()
    @State private var showCreateSheet = false
    // `.navigationDestination(item:)` es exclusiva de iOS 17+, no
    // compilaría contra el deployment target real de este proyecto (iOS
    // 16, mismo límite ya documentado en PerfilView.swift para
    // ChatListView/FollowListView) -- variante `(isPresented:)` con
    // estado aparte en su lugar.
    @State private var selectedGroup: GroupChat?
    @State private var showOpenedGroup = false

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.groups.isEmpty {
                ProgressView()
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if !viewModel.isLoading && viewModel.groups.isEmpty && viewModel.errorMessage == nil {
                Text("Todavía no tienes ningún grupo.").foregroundStyle(.secondary)
            }
            ForEach(viewModel.groups) { group in
                Button {
                    selectedGroup = group
                    showOpenedGroup = true
                } label: {
                    HStack {
                        // Foto de grupo real (0063_group_chat_photo.sql),
                        // comparado con WhatsApp/Messenger/Telegram --
                        // "👥" de respaldo mientras no se le ponga foto.
                        if let photoURLString = group.photoURL, let photoURL = URL(string: photoURLString) {
                            AsyncImage(url: photoURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color(.systemGray5))
                                .frame(width: 44, height: 44)
                                .overlay(Text("👥"))
                        }
                        // Fijar un chat de grupo arriba de la lista,
                        // comparado con WhatsApp/Telegram/Messenger -- ver
                        // 0081_pin_chats.sql.
                        if group.isPinnedForMe {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(group.name).font(.subheadline.bold())
                    }
                }
                .buttonStyle(.plain)
                // Silenciar un chat de grupo real (0064_group_chat_mute.sql),
                // comparado con WhatsApp/Instagram/Messenger -- mismo
                // patrón `.swipeActions` ya usado en ChatListView.swift
                // (chat 1:1).
                .swipeActions {
                    // Ocultar un chat de grupo real
                    // (0068_group_chat_hide.sql), comparado con WhatsApp/
                    // Instagram/Messenger -- mismo patrón que
                    // ChatListView.swift (chat 1:1).
                    Button("Ocultar", role: .destructive) {
                        Task { await viewModel.hideGroup(group) }
                    }
                    Button(group.isMutedForMe ? "Activar" : "Silenciar") {
                        Task { await viewModel.toggleMute(group) }
                    }
                    .tint(.gray)
                    // Fijar un chat de grupo arriba de la lista, comparado
                    // con WhatsApp/Telegram/Messenger -- ver
                    // GroupChatsViewModel.togglePin(), 0081_pin_chats.sql.
                    Button(group.isPinnedForMe ? "Desfijar" : "Fijar") {
                        Task { await viewModel.togglePin(group) }
                    }
                    .tint(.orange)
                }
            }
        }
        .navigationTitle("Grupos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showCreateSheet) {
            CreateGroupView(groupsViewModel: viewModel) { group in
                showCreateSheet = false
                Task { await viewModel.load() }
                selectedGroup = group
                showOpenedGroup = true
            }
        }
        .navigationDestination(isPresented: $showOpenedGroup) {
            if let selectedGroup {
                GroupChatView(groupChatID: selectedGroup.id, groupName: selectedGroup.name)
            }
        }
    }
}

private struct CreateGroupView: View {
    @ObservedObject var groupsViewModel: GroupChatsViewModel
    let onCreated: (GroupChat) -> Void
    @State private var name = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var creating = false
    @StateObject private var socialsViewModel = SocialsListViewModel()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre del grupo", text: $name)
                if !socialsViewModel.socials.isEmpty {
                    Section("Añadir a…") {
                        ForEach(socialsViewModel.socials) { entry in
                            let selected = selectedIDs.contains(entry.id)
                            HStack {
                                ActiveAvatarProvider.shared.avatarView(config: entry.avatarConfig ?? [:], size: 28)
                                Text(entry.displayName)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selected { selectedIDs.remove(entry.id) } else { selectedIDs.insert(entry.id) }
                            }
                        }
                    }
                }
                Button {
                    creating = true
                    Task {
                        let group = await groupsViewModel.createGroup(name: name, initialMemberIDs: Array(selectedIDs))
                        creating = false
                        if let group { onCreated(group) }
                    }
                } label: {
                    if creating {
                        ProgressView()
                    } else {
                        Text("Crear grupo").frame(maxWidth: .infinity)
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
            }
            .navigationTitle("Nuevo grupo")
            .task { await socialsViewModel.load() }
        }
    }
}
