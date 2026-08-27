//
//  BroadcastListsView.swift
//  Social
//
//  Listas de difusión reales, comparado con WhatsApp -- ver
//  BroadcastListsViewModel.swift para el hallazgo completo
//  (0103_broadcast_lists.sql). Pantalla única: la lista de listas, y al
//  tocar una, sus miembros + el compositor para mandarle un mensaje real
//  de un tirón. Equivalente de BroadcastListsScreen.kt.
//

import SwiftUI

struct BroadcastListsView: View {
    @StateObject private var viewModel = BroadcastListsViewModel()
    @State private var selectedList: BroadcastList?
    @State private var showNewListSheet = false
    @State private var newListName = ""
    @State private var showAddMember = false
    @State private var draft = ""

    var body: some View {
        Group {
            if let current = selectedList {
                detail(for: current)
            } else {
                listOfLists
            }
        }
        .navigationTitle("Difusión")
        .task { await viewModel.load() }
        .sheet(isPresented: $showNewListSheet) {
            NavigationStack {
                Form {
                    TextField("Nombre (p. ej. \"Amigos cercanos\")", text: $newListName)
                }
                .navigationTitle("Nueva lista")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar") { showNewListSheet = false; newListName = "" }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Crear") {
                            let name = newListName
                            showNewListSheet = false
                            newListName = ""
                            Task { await viewModel.createList(name) }
                        }
                        .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(160)])
        }
    }

    private var listOfLists: some View {
        List {
            Section {
                Button("+ Nueva lista de difusión") { showNewListSheet = true }
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
            ForEach(viewModel.lists) { list in
                Button {
                    selectedList = list
                    Task { await viewModel.loadMembers(list.id) }
                } label: {
                    Text("📢 \(list.name)")
                }
                .swipeActions {
                    Button("Borrar", role: .destructive) {
                        Task { await viewModel.deleteList(list.id) }
                    }
                }
            }
            if viewModel.lists.isEmpty {
                Text("Todavía no tienes ninguna lista de difusión.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(for list: BroadcastList) -> some View {
        VStack(spacing: 0) {
            List {
                ForEach(viewModel.members) { member in
                    HStack {
                        Text(member.displayName)
                        Spacer()
                        Button("Quitar") {
                            Task { await viewModel.removeMember(listID: list.id, memberID: member.id) }
                        }
                        .font(.footnote)
                    }
                }
                Button("+ Añadir persona") { showAddMember = true }
            }
            if let sendResult = viewModel.sendResult {
                Text(sendResult).foregroundStyle(Color.accentColor).font(.footnote).padding(.horizontal)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote).padding(.horizontal)
            }
            HStack {
                TextField("Mensaje para toda la lista…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("➤") {
                    let text = draft
                    draft = ""
                    Task { await viewModel.sendBroadcast(text) }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.members.isEmpty)
            }
            .padding()
        }
        .navigationTitle(list.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("‹ Listas") { selectedList = nil }
            }
        }
        .sheet(isPresented: $showAddMember) {
            addMemberSheet(for: list)
        }
    }

    private func addMemberSheet(for list: BroadcastList) -> some View {
        let alreadyMemberIDs = Set(viewModel.members.map { $0.id })
        let candidates = viewModel.myFollowing.filter { !alreadyMemberIDs.contains($0.id) }
        return NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("No sigues a nadie más que ya no esté en la lista.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { person in
                        Button(person.displayName) {
                            let name = person.displayName
                            let id = person.id
                            showAddMember = false
                            Task { await viewModel.addMember(listID: list.id, memberID: id, displayName: name) }
                        }
                    }
                }
            }
            .navigationTitle("Añadir persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { showAddMember = false }
                }
            }
        }
    }
}
