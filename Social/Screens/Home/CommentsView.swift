//
//  CommentsView.swift
//  Social
//
//  Hoja de comentarios de un post — equivalente de CommentsSheet.kt.
//

import SwiftUI

struct CommentsView: View {
    @StateObject private var viewModel: CommentsViewModel
    @State private var draft = ""
    @State private var myID: UUID?
    // Hallazgo real: mismo patrón que "Denunciar publicación" — solo
    // existía denuncia global de usuario, ahora también por comentario
    // concreto.
    @State private var reportingComment: Comment?
    let onCommentAdded: () -> Void
    var onCommentRemoved: () -> Void = {}

    init(postID: UUID, onCommentAdded: @escaping () -> Void, onCommentRemoved: @escaping () -> Void = {}) {
        self._viewModel = StateObject(wrappedValue: CommentsViewModel(postID: postID))
        self.onCommentAdded = onCommentAdded
        self.onCommentRemoved = onCommentRemoved
    }

    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.isLoading && viewModel.comments.isEmpty {
                    ProgressView()
                }
                if let error = viewModel.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                // Hallazgo real: no había forma de borrar el propio
                // comentario, comparado con cualquier app grande.
                List(viewModel.comments) { comment in
                    HStack {
                        Text(comment.body)
                        Spacer()
                        if comment.author_id == myID {
                            Button("Borrar", role: .destructive) {
                                Task { await viewModel.deleteComment(comment, onCommentRemoved: onCommentRemoved) }
                            }
                            .font(.caption)
                        } else {
                            Button("⋯") { reportingComment = comment }
                                .font(.caption)
                        }
                    }
                }
                .listStyle(.plain)

                HStack {
                    TextField("Escribe un comentario…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                    Button("➤") {
                        Task {
                            await viewModel.addComment(draft, onCommentAdded: onCommentAdded)
                            draft = ""
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Comentarios")
            .task {
                await viewModel.load()
                myID = try? await SupabaseManager.shared.client.auth.session.user.id
            }
            .sheet(item: $reportingComment) { comment in
                if let myID {
                    ReportSheet(userID: myID, reportedID: comment.author_id, initialDetails: "Comentario \(comment.id)")
                }
            }
        }
    }
}
