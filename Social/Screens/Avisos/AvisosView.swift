//
//  AvisosView.swift
//  Social
//
//  Lista de notificaciones. Al tocar una, hoja con todas las acciones
//  posibles sobre ese perfil (aceptar social, seguir, ver duelo, etc.).
//

import SwiftUI

struct AvisosView: View {

    @StateObject private var viewModel = AvisosViewModel()

    var body: some View {
        NavigationStack {
            List(viewModel.notifications) { entry in
                Button {
                    viewModel.selected = entry
                    Task { await viewModel.markRead(entry) }
                } label: {
                    HStack(spacing: 14) {
                        // Hallazgo real, mismo hueco raíz ya cerrado en el
                        // feed/comentarios/chats/duelos: solo había un
                        // icono genérico por tipo, nunca el avatar de
                        // quién disparó el aviso -- comparado con la
                        // pestaña "Actividad" de Instagram.
                        let actorAvatar = entry.payload["actor_id"]
                            .flatMap { UUID(uuidString: $0) }
                            .flatMap { viewModel.actorProfiles[$0] }
                        ActiveAvatarProvider.shared.avatarView(config: actorAvatar?.avatarConfig ?? [:], size: 40)

                        Image(systemName: entry.icon)
                            .frame(width: 20)
                            .foregroundStyle(entry.readAt == nil ? .pink : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.subheadline.bold())
                            Text(entry.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.readAt == nil {
                            Circle().fill(.pink).frame(width: 8, height: 8)
                        }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Avisos")
            // Hallazgo real, comparado con Gmail/Instagram/Twitter:
            // cualquier lista de notificaciones grande deja marcar todo
            // como leído de una vez, no solo aviso por aviso.
            .toolbar {
                if viewModel.notifications.contains(where: { $0.readAt == nil }) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Marcar todo leído") {
                            Task { await viewModel.markAllRead() }
                        }
                    }
                }
            }
            .task { await viewModel.start() }
            .onDisappear { Task { await viewModel.stop() } }
            // Hallazgo real: comparado con Instagram/Twitter/Facebook (y
            // con Home/Match, ya con .refreshable), Avisos no tenía
            // pull-to-refresh. load() no vuelve a suscribirse a Realtime
            // (start() ya lo hizo una vez), evitando un canal duplicado.
            .refreshable { await viewModel.load() }
            .sheet(item: $viewModel.selected) { entry in
                NotificationActionsSheet(entry: entry)
                    .presentationDetents([.medium])
            }
        }
    }
}

private struct NotificationActionsSheet: View {
    let entry: AvisosViewModel.NotificationEntry
    @StateObject private var socialLinks = SocialLinkManager()
    @StateObject private var follows = FollowManager()
    @StateObject private var compatRequests = CompatRequestManager()
    @Environment(\.dismiss) private var dismiss
    @State private var showProfile = false
    @State private var showDuelResult = false

    /// El id del emisor viaja en el payload de la notificación (guardado al
    /// crearla en el backend); sin él no se puede responder al social desde aquí.
    private var actorSocialID: UUID? {
        entry.payload["social_id"].flatMap(UUID.init)
    }

    /// Ver aviso de honestidad en FollowManager.swift sobre esta convención.
    private var actorProfileID: UUID? {
        entry.payload["actor_id"].flatMap(UUID.init)
    }

    /// Ver aviso de honestidad en CompatRequestManager.swift.
    private var compatRequestID: UUID? {
        entry.payload["compat_request_id"].flatMap(UUID.init)
    }

    /// Ver aviso de honestidad en DuelResultView.swift.
    private var duelID: UUID? {
        entry.payload["duel_id"].flatMap(UUID.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.title)
                .font(.title3.bold())

            switch entry.kind {
            case "social":
                Button("Aceptar social") {
                    respond(accept: true)
                }.buttonStyle(.borderedProminent)
                Button("Rechazar") {
                    respond(accept: false)
                }.buttonStyle(.bordered)
            case "follow":
                Button("Seguir de vuelta") {
                    followBack()
                }.buttonStyle(.borderedProminent)
            case "fight":
                if duelID != nil {
                    Button("Ver duelo") { showDuelResult = true }.buttonStyle(.borderedProminent)
                }
            case "compat_request":
                Button("Compartir compatibilidad") {
                    respondCompat(accept: true)
                }.buttonStyle(.borderedProminent)
                Button("Rechazar") {
                    respondCompat(accept: false)
                }.buttonStyle(.bordered)
            default:
                EmptyView()
            }

            if actorProfileID != nil {
                Button("Ver perfil") { showProfile = true }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(24)
        .sheet(isPresented: $showProfile) {
            if let actorProfileID {
                NavigationStack { ProfileViewerView(profileID: actorProfileID) }
            }
        }
        .sheet(isPresented: $showDuelResult) {
            if let duelID {
                DuelResultView(duelID: duelID)
            }
        }
    }

    private func respond(accept: Bool) {
        guard let socialID = actorSocialID else { return }
        Task {
            await socialLinks.respond(socialID: socialID, accept: accept)
            if accept { AnalyticsManager.track("social_accepted") }
            dismiss()
        }
    }

    private func followBack() {
        guard let followeeID = actorProfileID else { return }
        Task {
            guard let myID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            await follows.follow(followerID: myID, followeeID: followeeID)
            dismiss()
        }
    }

    private func respondCompat(accept: Bool) {
        guard let requestID = compatRequestID else { return }
        Task {
            await compatRequests.respond(requestID: requestID, accept: accept)
            dismiss()
        }
    }
}
