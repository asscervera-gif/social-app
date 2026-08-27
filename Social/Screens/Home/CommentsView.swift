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
    // Responder a un comentario concreto (hilo de un nivel), comparado
    // con Instagram/Facebook/Twitter/TikTok -- ver
    // CommentsViewModel.addComment(), 0104_comment_replies.sql.
    @State private var replyingToComment: Comment?
    // Editar un comentario ya publicado, comparado con
    // Instagram/Facebook/Twitter/TikTok -- ver
    // CommentsViewModel.editComment(), 0123_comment_edit.sql.
    @State private var editingCommentID: UUID?
    @State private var editDraft = ""
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
                    // Responder a un comentario concreto (hilo de un
                    // nivel), comparado con Instagram/Facebook/Twitter/
                    // TikTok -- una respuesta real va sangrada bajo el
                    // comentario de primer nivel que responde (ya en el
                    // orden correcto real, ver
                    // CommentsViewModel.threadOrder()).
                    let isReply = comment.parent_comment_id != nil
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

                        if editingCommentID == comment.id {
                            TextField("Editar comentario", text: $editDraft)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            if comment.edited_at != nil {
                                Text("(editado)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            if editingCommentID != comment.id {
                                MentionHashtagText(
                                    text: comment.body,
                                    font: .body,
                                    onOpenMention: { username in
                                        Task { mentionProfileID = await MentionResolver.resolveProfileID(username: username) }
                                    }
                                )
                            }
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
                            // Responder a un comentario concreto (hilo de
                            // un nivel), comparado con Instagram/Facebook/
                            // Twitter/TikTok -- solo sobre un comentario
                            // de primer nivel (límite real de un solo
                            // nivel, 0104_comment_replies.sql).
                            if !isReply {
                                Button("Responder") { replyingToComment = comment }
                                    .font(.caption)
                            }
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
                            // Editar un comentario ya publicado, comparado
                            // con Instagram/Facebook/Twitter/TikTok --
                            // solo visible para el propio autor real,
                            // mismo criterio que `comments_update_own` en
                            // RLS.
                            if comment.author_id == myID {
                                if editingCommentID == comment.id {
                                    Button("Guardar") {
                                        Task { await viewModel.editComment(comment, newBody: editDraft) }
                                        editingCommentID = nil
                                    }
                                    .font(.caption)
                                    Button("Cancelar") { editingCommentID = nil }
                                        .font(.caption)
                                } else {
                                    Button("Editar") {
                                        editingCommentID = comment.id
                                        editDraft = comment.body
                                    }
                                    .font(.caption)
                                }
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
                    .padding(.leading, isReply ? 24 : 0)
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
                    // Responder a un comentario concreto (hilo de un
                    // nivel), comparado con Instagram/Facebook/Twitter/
                    // TikTok -- vista previa real de a qué comentario se
                    // está respondiendo, cancelable antes de publicar.
                    if let replyTarget = replyingToComment {
                        HStack {
                            Text("Respondiendo a \(viewModel.authorProfiles[replyTarget.author_id]?.displayName ?? "…")")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            Button("✕") { replyingToComment = nil }
                        }
                        .padding(.horizontal)
                    }
                    HStack {
                        TextField(replyingToComment != nil ? "Escribe una respuesta…" : "Escribe un comentario…", text: $draft)
                            .textFieldStyle(.roundedBorder)
                        Button("➤") {
                            let parentID = replyingToComment?.id
                            Task {
                                await viewModel.addComment(draft, parentCommentID: parentID, onCommentAdded: onCommentAdded)
                                draft = ""
                                replyingToComment = nil
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
