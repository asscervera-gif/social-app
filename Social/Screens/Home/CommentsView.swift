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
                    VStack(alignment: .leading, spacing: 4) {
                        // Hallazgo real, mismo hueco raíz que el feed
                        // (HomeViewModel.authorProfiles) -- nunca se
                        // mostraba QUIÉN escribió cada comentario,
                        // comparado con cualquier app grande.
                        NavigationLink {
                            ProfileViewerView(profileID: comment.author_id)
                        } label: {
                            HStack(spacing: 6) {
                                ActiveAvatarProvider.shared.avatarView(
                                    config: viewModel.authorProfiles[comment.author_id]?.avatarConfig ?? [:],
                                    size: 20
                                )
                                Text(viewModel.authorProfiles[comment.author_id]?.displayName ?? "…")
                                    .font(.caption.bold())
                            }
                        }
                        .buttonStyle(.plain)

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
                    // Hallazgo real, comparado con Instagram/TikTok/
                    // Facebook: antes esto era un texto libre editable;
                    // ahora una referencia real
                    // (0045_reports_content_reference.sql).
                    ReportSheet(userID: myID, reportedID: comment.author_id, commentID: comment.id)
                }
            }
        }
    }
}
