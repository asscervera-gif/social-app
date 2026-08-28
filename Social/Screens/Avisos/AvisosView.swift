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
    // Hallazgo real, el hueco de mensajería más grande de la sesión:
    // ningún mensaje nuevo generaba nunca un aviso -- ver
    // 0047_message_notify_mute.sql. Mismo patrón ya usado en
    // PerfilView.swift para abrir un chat desde "Tus chats"
    // (`.navigationDestination(isPresented:)`, no `(item:)` -- exclusivo
    // de iOS 17+, no compila contra el deployment target real de este
    // proyecto, iOS 16).
    @State private var selectedChatID: UUID?
    @State private var showOpenedChat = false
    @State private var currentUserID: UUID?
    // Publicación individual real, comparado con Instagram/Twitter/
    // Facebook -- ver PostDetailView.swift para el hallazgo completo: un
    // aviso de "like"/"comentario" no llevaba a ningún sitio.
    @State private var selectedPostID: UUID?
    @State private var showOpenedPost = false
    // Hallazgo real de paso: mismo hueco exacto que "message" pero para
    // un mensaje de GRUPO (0058_group_message_notify.sql ya manda
    // group_chat_id desde esa ronda, sin cliente que lo usara).
    @State private var selectedGroupChatID: UUID?
    @State private var showOpenedGroupChat = false
    // Abrir un reel concreto real, comparado con Instagram/TikTok -- ver
    // ReelsViewModel.swift.load() para el hallazgo completo.
    @State private var selectedReelID: UUID?
    @State private var showOpenedReel = false

    var body: some View {
        NavigationStack {
            List(viewModel.notifications) { entry in
                AvisoRow(
                    entry: entry,
                    actorProfile: entry.payload["actor_id"].flatMap { UUID(uuidString: $0) }.flatMap { viewModel.actorProfiles[$0] },
                    onTap: {
                        Task { await viewModel.markRead(entry) }
                        handleTap(on: entry)
                    }
                )
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
            .task { currentUserID = try? await SupabaseManager.shared.client.auth.session.user.id }
            .navigationDestination(isPresented: $showOpenedChat) { chatDestination }
            .navigationDestination(isPresented: $showOpenedPost) { postDestination }
            .navigationDestination(isPresented: $showOpenedGroupChat) { groupChatDestination }
            .navigationDestination(isPresented: $showOpenedReel) { reelDestination }
            .onDisappear { Task { await viewModel.stop() } }
            // Hallazgo real: comparado con Instagram/Twitter/Facebook (y
            // con Home/Match, ya con .refreshable), Avisos no tenía
            // pull-to-refresh. load() no vuelve a suscribirse a Realtime
            // (start() ya lo hizo una vez), evitando un canal duplicado.
            .refreshable { await viewModel.load() }
            .sheet(item: $viewModel.selected) { entry in
                let actorProfile: Profile? = entry.payload["actor_id"]
                    .flatMap { UUID(uuidString: $0) }
                    .flatMap { viewModel.actorProfiles[$0] }
                NotificationActionsSheet(entry: entry, actorProfile: actorProfile)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // Contenido de cada `.navigationDestination(isPresented:)` extraído a
    // su propia propiedad -- mismo hallazgo real de compilador que
    // `handleTap(on:)` (ver más abajo): con las CUATRO ramas `if let`
    // inline dentro de `body` (chat/post/grupo/reel), el type-checker de
    // Swift tampoco terminaba. Cada propiedad se type-checka por
    // separado, sin acumularse en la misma expresión que `body`.
    @ViewBuilder private var chatDestination: some View {
        if let selectedChatID, let currentUserID {
            ChatView(chatID: selectedChatID, currentUserID: currentUserID)
        }
    }

    @ViewBuilder private var postDestination: some View {
        if let selectedPostID {
            PostDetailView(postID: selectedPostID)
        }
    }

    @ViewBuilder private var groupChatDestination: some View {
        if let selectedGroupChatID {
            GroupChatView(groupChatID: selectedGroupChatID, groupName: "Grupo")
        }
    }

    @ViewBuilder private var reelDestination: some View {
        if let selectedReelID {
            ReelsView(initialReelID: selectedReelID)
        }
    }

    /// Decide a dónde lleva tocar un aviso real, según su `kind` y los
    /// datos reales de su `payload`. Extraído de `body` a propósito --
    /// hallazgo real de compilador (CI real, GitHub Actions, 2026-08-26):
    /// con cinco ramas `if/else if` encadenadas (varias con `||` y
    /// múltiples `let` en la misma condición) DENTRO del closure de
    /// `Button` en un result builder de SwiftUI, el type-checker no
    /// terminaba ("unable to type-check this expression in reasonable
    /// time") -- un método normal, fuera de cualquier result builder,
    /// type-checka cada rama por separado sin ese límite combinatorio.
    private func handleTap(on entry: AvisosViewModel.NotificationEntry) {
        if entry.kind == "message",
           let chatIDString = entry.payload["chat_id"],
           let chatID = UUID(uuidString: chatIDString) {
            selectedChatID = chatID
            showOpenedChat = true
            return
        }
        // "comment_like" real (0070_notify_comment_like_post_reference.sql):
        // mismo hueco exacto que like/comment, pero para un like a un
        // COMENTARIO -- payload.post_id no existía hasta esa migración.
        if entry.kind == "like" || entry.kind == "comment" || entry.kind == "comment_like",
           let postIDString = entry.payload["post_id"],
           let postID = UUID(uuidString: postIDString) {
            selectedPostID = postID
            showOpenedPost = true
            return
        }
        if entry.kind == "group_message",
           let groupChatIDString = entry.payload["group_chat_id"],
           let groupChatID = UUID(uuidString: groupChatIDString) {
            selectedGroupChatID = groupChatID
            showOpenedGroupChat = true
            return
        }
        // @menciones reales (0074_mentions.sql), comparado con Instagram/
        // Twitter/TikTok -- el payload trae post_id O reel_id según dónde
        // se escribió el @usuario (mismo criterio que AvisosScreen.kt).
        if entry.kind == "mention",
           let postIDString = entry.payload["post_id"],
           let postID = UUID(uuidString: postIDString) {
            selectedPostID = postID
            showOpenedPost = true
            return
        }
        // Abrir un reel concreto real, comparado con Instagram/TikTok --
        // cierra el hueco documentado dos rondas atrás.
        if entry.kind == "reel_like" || entry.kind == "reel_comment" || entry.kind == "reel_comment_like",
           let reelIDString = entry.payload["reel_id"],
           let reelID = UUID(uuidString: reelIDString) {
            selectedReelID = reelID
            showOpenedReel = true
            return
        }
        if entry.kind == "mention",
           let reelIDString = entry.payload["reel_id"],
           let reelID = UUID(uuidString: reelIDString) {
            selectedReelID = reelID
            showOpenedReel = true
            return
        }
        // Activar avisos de publicaciones de una cuenta real ("🔔"),
        // comparado con Instagram/Twitter/X -- ver
        // 0098_post_notifications.sql.
        if entry.kind == "new_post",
           let postIDString = entry.payload["post_id"],
           let postID = UUID(uuidString: postIDString) {
            selectedPostID = postID
            showOpenedPost = true
            return
        }
        // Repostear una publicación real, comparado con Twitter/X/
        // Facebook -- mismo criterio de navegación directa que like/
        // comment. Ver HomeViewModel.toggleRepost(), 0127_post_reposts.sql.
        if entry.kind == "repost",
           let postIDString = entry.payload["post_id"],
           let postID = UUID(uuidString: postIDString) {
            selectedPostID = postID
            showOpenedPost = true
            return
        }
        viewModel.selected = entry
    }
}

/// Fila de un aviso real -- extraída de `AvisosView.body` a propósito,
/// mismo hallazgo real de compilador (CI real, GitHub Actions,
/// 2026-08-26): el type-checker de Swift no terminaba con el `Button`/
/// `HStack` de la fila inline dentro del `List` de `body`. Una vista
/// propia se type-checka por separado, sin acumularse en la misma
/// expresión.
private struct AvisoRow: View {
    let entry: AvisosViewModel.NotificationEntry
    let actorProfile: Profile?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Hallazgo real, mismo hueco raíz ya cerrado en el feed/
                // comentarios/chats/duelos: solo había un icono genérico
                // por tipo, nunca el avatar de quién disparó el aviso --
                // comparado con la pestaña "Actividad" de Instagram.
                ActiveAvatarProvider.shared.avatarView(config: actorProfile?.avatarConfig ?? [:], size: 40)

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
}

/// Frase de contexto por tipo de aviso -- mismo criterio que `context` en
/// el `openSheet()` de SOCIAL_APP.html: explica qué significa el aviso
/// antes de mostrar las acciones, en vez de solo un título suelto.
/// Equivalente exacto de contextFor() en AvisosScreen.kt.
private func contextFor(_ kind: String) -> String {
    switch kind {
    case "social": return "Te ha enviado un social. Acéptalo para conectar."
    case "follow": return "Ha solicitado seguirte."
    case "fight": return "Te ha retado a un duelo de preguntas."
    case "compat_request": return "Quiere ver vuestra compatibilidad. Acéptalo para desvelarla mutuamente."
    case "like", "comment", "reel_like", "reel_comment": return "Ha interactuado con tu contenido."
    case "mention": return "Te ha mencionado."
    case "social_accepted": return "Aceptó tu social."
    case "compat_accepted": return "Compartió su compatibilidad contigo."
    case "new_post": return "Ha publicado algo nuevo."
    default: return "Nueva notificación."
    }
}

/// Hoja de acciones al tocar un aviso -- reconstruida siguiendo la
/// ESTRUCTURA exacta de `openSheet()` en SOCIAL_APP.html (el boceto pedido
/// "exactamente igual"): cabecera con avatar+nombre real, frase de
/// contexto, acción primaria según el tipo, y un menú universal de
/// acciones (mensaje/social/perfil/bloquear) que antes no existía -- solo
/// había botones sueltos condicionados a que el payload trajera una clave
/// concreta, sin cabecera ni contexto ni forma de mandar mensaje o social
/// directamente desde aquí. Equivalente exacto de NotificationActionsSheet
/// (AvisosScreen.kt).
private struct NotificationActionsSheet: View {
    let entry: AvisosViewModel.NotificationEntry
    let actorProfile: Profile?
    @StateObject private var socialLinks = SocialLinkManager()
    @StateObject private var follows = FollowManager()
    @StateObject private var compatRequests = CompatRequestManager()
    @Environment(\.dismiss) private var dismiss
    @State private var showProfile = false
    @State private var showDuelResult = false
    @State private var showChat = false
    @State private var showReport = false
    @State private var currentUserID: UUID?
    @State private var chatID: UUID?
    // Retar a duelo real desde cualquier aviso, comparado con
    // WhatsApp/Instagram -- ver startDuel(with:).
    @State private var showDuel = false
    @State private var duelChatID: UUID?
    @State private var duelOpponentID: UUID?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ActiveAvatarProvider.shared.avatarView(config: actorProfile?.avatarConfig ?? [:], size: 52)
                    Text(actorProfile?.displayName ?? entry.title)
                        .font(.title3.bold())
                }
                Text(contextFor(entry.kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                switch entry.kind {
                case "social":
                    Button("✓ Aceptar social") {
                        respond(accept: true)
                    }.buttonStyle(.borderedProminent).tint(.green)
                    Button("✕ Rechazar") {
                        respond(accept: false)
                    }.buttonStyle(.bordered)
                case "follow":
                    Button("✓ Seguir de vuelta") {
                        followBack()
                    }.buttonStyle(.borderedProminent).tint(.green)
                case "fight":
                    if duelID != nil {
                        Button("⚔️ Ver duelo") { showDuelResult = true }.buttonStyle(.borderedProminent).tint(.purple)
                    }
                case "compat_request":
                    Button("✓ Mostrar compatibilidad") {
                        respondCompat(accept: true)
                    }.buttonStyle(.borderedProminent).tint(.green)
                    Button("✕ Denegar") {
                        respondCompat(accept: false)
                    }.buttonStyle(.bordered)
                default:
                    EmptyView()
                }

                // Menú universal -- hallazgo real comparado con Instagram/
                // WhatsApp: antes no había forma de mandar un mensaje o un
                // social directamente desde un aviso, solo responder al
                // aviso concreto o navegar al perfil. `getOrCreateChat`
                // (nuevo, SocialLinkManager.swift) crea el chat si hace
                // falta, mismo criterio que "mensaje directo" en cualquier
                // app grande.
                if let actorProfileID {
                    Button("💬 Enviar mensaje") { sendMessage(to: actorProfileID) }
                        .buttonStyle(.borderedProminent).tint(.blue)
                    // Retar a duelo real desde cualquier aviso, comparado
                    // con WhatsApp/Instagram -- cierra el hueco deliberado
                    // documentado hace varias rondas: los duelos
                    // necesitaban un chatID existente, ahora resuelto
                    // reutilizando el mismo getOrCreateChat() de arriba
                    // (mismo criterio real que "Enviar mensaje").
                    Button("⚡ Retar a duelo") { startDuel(with: actorProfileID) }
                        .buttonStyle(.bordered)
                    if entry.kind != "social" {
                        Button("🤝 Enviar social") { sendSocial(to: actorProfileID) }
                            .buttonStyle(.bordered)
                    }
                    Button("👤 Ver perfil") { showProfile = true }
                        .buttonStyle(.bordered)
                    Button("🚫 Bloquear o denunciar") { showReport = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { currentUserID = try? await SupabaseManager.shared.client.auth.session.user.id }
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
        .sheet(isPresented: $showChat) {
            if let chatID, let currentUserID {
                NavigationStack { ChatView(chatID: chatID, currentUserID: currentUserID) }
            }
        }
        .sheet(isPresented: $showDuel) {
            if let duelChatID, let currentUserID, let duelOpponentID {
                DuelEntryPoint(chatID: duelChatID, currentUserID: currentUserID, opponentID: duelOpponentID)
            }
        }
        .sheet(isPresented: $showReport) {
            if let currentUserID, let actorProfileID {
                ReportSheet(userID: currentUserID, reportedID: actorProfileID)
            }
        }
    }

    private func sendMessage(to otherID: UUID) {
        Task {
            // Nota real de compilación: `currentUserID ?? (try? await ...)`
            // no compila en el Xcode real de CI ("'async' property access
            // in a function that does not support concurrency") -- el
            // operador `??` no admite un autoclosure async+try? en esta
            // posición. Resuelto con un if/else explícito en vez del
            // operador, mismo resultado.
            let resolvedID: UUID?
            if let currentUserID {
                resolvedID = currentUserID
            } else {
                resolvedID = try? await SupabaseManager.shared.client.auth.session.user.id
            }
            guard let myID = resolvedID else { return }
            chatID = await socialLinks.getOrCreateChat(myID, otherID)
            if chatID != nil { showChat = true }
        }
    }

    /// Retar a duelo real desde cualquier aviso, comparado con
    /// WhatsApp/Instagram -- cierra el hueco deliberado documentado hace
    /// varias rondas: los duelos necesitaban un chatID existente para
    /// poder challengear, ahora resuelto reutilizando el mismo
    /// getOrCreateChat() que sendMessage(to:) de arriba.
    private func startDuel(with otherID: UUID) {
        Task {
            let resolvedID: UUID?
            if let currentUserID {
                resolvedID = currentUserID
            } else {
                resolvedID = try? await SupabaseManager.shared.client.auth.session.user.id
            }
            guard let myID = resolvedID else { return }
            duelChatID = await socialLinks.getOrCreateChat(myID, otherID)
            duelOpponentID = otherID
            if duelChatID != nil { showDuel = true }
        }
    }

    private func sendSocial(to otherID: UUID) {
        Task {
            let resolvedID: UUID?
            if let currentUserID {
                resolvedID = currentUserID
            } else {
                resolvedID = try? await SupabaseManager.shared.client.auth.session.user.id
            }
            guard let myID = resolvedID else { return }
            await socialLinks.sendSocial(from: myID, to: otherID)
            dismiss()
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
