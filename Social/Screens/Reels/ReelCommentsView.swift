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
                            }
                        }
                        .buttonStyle(.plain)

                        HStack {
                            Text(comment.body)
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
            .sheet(isPresented: Binding(
                get: { reportingAuthorID != nil },
                set: { isPresented in if !isPresented { reportingAuthorID = nil } }
            )) {
                if let myID, let reportingAuthorID {
                    ReportSheet(userID: myID, reportedID: reportingAuthorID)
                }
            }
        }
    }
}
