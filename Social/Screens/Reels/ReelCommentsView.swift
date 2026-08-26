//
//  ReelCommentsView.swift
//  Social
//
//  Hoja de comentarios de un reel -- hueco real cerrado en esta pasada,
//  ver ReelCommentsViewModel.swift. Mismo patrón visual exacto que
//  CommentsView.swift (posts). Equivalente de ReelCommentsSheet.kt.
//
//  Aviso de honestidad: a diferencia de "Denunciar comentario" en posts
//  (0045_reports_content_reference.sql, referencia real al comment_id),
//  un comentario de reel se denuncia contra el AUTOR sin una columna
//  `reel_comment_id` propia en `reports` todavía -- mismo criterio que
//  tenían los comentarios de posts antes de esa migración. Hueco real
//  documentado, no fingido con una columna inventada.
//

import SwiftUI

struct ReelCommentsView: View {
    @StateObject private var viewModel: ReelCommentsViewModel
    @State private var draft = ""
    @State private var myID: UUID?
    @State private var reportingAuthorID: UUID?
    // Nombre de usuario único real (@handle, 0073_profile_username.sql) +
    // notificación real de mención (0074_mentions.sql), comparado con
    // Instagram/TikTok -- mismo criterio que CommentsView.swift (posts).
    @State private var mentionProfileID: UUID?
    let onCommentAdded: () -> Void
    var onCommentRemoved: () -> Void = {}

    init(reelID: UUID, onCommentAdded: @escaping () -> Void, onCommentRemoved: @escaping () -> Void = {}) {
        self._viewModel = StateObject(wrappedValue: ReelCommentsViewModel(reelID: reelID))
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
                List(viewModel.comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
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
                                // ReelCommentsViewModel.togglePin(),
                                // 0084_pin_comments.sql.
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
                            // like a un comentario concreto (0054_comment_likes.sql).
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
                            // visible para el autor real del reel, mismo
                            // criterio que `reel_comments_update_pin` en
                            // RLS.
                            if let reelAuthorID = viewModel.reelAuthorID, reelAuthorID == myID {
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
                                Button("⋯") { reportingAuthorID = comment.author_id }
                                    .font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.plain)

                // Desactivar los comentarios de un reel, comparado con
                // Instagram/TikTok -- el autor real cerró la puerta a
                // comentarios nuevos (0086_disable_comments.sql); los que
                // ya existían se siguen viendo con normalidad arriba.
                if viewModel.commentsDisabled {
                    Text("El autor ha desactivado los comentarios en este reel.")
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
            .sheet(isPresented: Binding(
                get: { reportingAuthorID != nil },
                set: { isPresented in if !isPresented { reportingAuthorID = nil } }
            )) {
                if let myID, let reportingAuthorID {
                    ReportSheet(userID: myID, reportedID: reportingAuthorID)
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
