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
    // Nombre de usuario único real (@handle, 0073_profile_username.sql) +
    // notificación real de mención (0074_mentions.sql), comparado con
    // Instagram/Twitter/TikTok.
    @State private var mentionProfileID: UUID?
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
                                // Fijar un comentario, comparado con
                                // Instagram/Twitter -- ver
                                // CommentsViewModel.togglePin(),
                                // 0084_pin_comments.sql. El propio icono ya
                                // comunica el estado, visible para
                                // cualquiera (mismo criterio que WhatsApp
                                // con "Fijado").
                                if comment.is_pinned {
                                    Text("📌").font(.caption)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        HStack {
                            MentionHashtagText(
                                text: comment.body,
                                font: .body,
                                onOpenMention: { username in
                                    Task { mentionProfileID = await MentionResolver.resolveProfileID(username: username) }
                                }
                            )
                            Spacer()
                            // Comparado con Instagram/Twitter/Facebook: dar
                            // like a un comentario concreto, no solo a la
                            // publicación entera (0054_comment_likes.sql).
                            Button {
                                Task { await viewModel.toggleCommentLike(comment) }
                            } label: {
                                HStack(spacing: 2) {
                                    Text(viewModel.likedCommentIDs.contains(comment.id) ? "❤" : "🤍")
                                    if comment.like_count > 0 {
                                        Text("\(comment.like_count)").font(.caption2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            // Fijar un comentario (propio o ajeno),
                            // comparado con Instagram/Twitter -- solo
                            // visible para el autor real de la
                            // publicación, mismo criterio que
                            // `comments_update_pin` en RLS.
                            if let postAuthorID = viewModel.postAuthorID, postAuthorID == myID {
                                Button(comment.is_pinned ? "Desfijar" : "Fijar") {
                                    Task { await viewModel.togglePin(comment) }
                                }
                                .font(.caption)
                            }
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

                // Desactivar los comentarios de una publicación, comparado
                // con Instagram/TikTok -- el autor real cerró la puerta a
                // comentarios nuevos (0086_disable_comments.sql); los que
                // ya existían se siguen viendo con normalidad arriba.
                if viewModel.commentsDisabled {
                    Text("El autor ha desactivado los comentarios en esta publicación.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
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
            .navigationDestination(isPresented: Binding(
                get: { mentionProfileID != nil },
                set: { isPresented in if !isPresented { mentionProfileID = nil } }
            )) {
                if let mentionProfileID {
                    ProfileViewerView(profileID: mentionProfileID)
                }
            }
        }
    }
}
