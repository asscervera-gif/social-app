//
//  PerfilView.swift
//  Social
//
//  Cabecera con avatar y foto alternándose, contadores, acceso a "Mi perfil
//  completo" (15 secciones editables con marca público/privado), y seis
//  secciones: Avatar, Reels, Fights, Publicaciones de socials, En directo,
//  Tus publicaciones.
//

import SwiftUI

struct PerfilView: View {

    @StateObject private var viewModel = PerfilViewModel()
    @State private var showFullProfile = false
    @State private var showClothingStore = false
    @State private var showAjustes = false
    @State private var showDuelHistory = false
    // Hallazgo real: no había ningún punto de entrada a la lista de chats
    // en ninguna plataforma (ver ChatListViewModel.swift).
    @State private var showChatList = false
    @State private var showGroupChats = false
    @State private var selectedChatID: UUID?
    @State private var showOpenedChat = false
    // Hallazgo real: "Tus publicaciones" estaba vacío, documentado como
    // bloqueado por Storage — ya no lo está para publicaciones de texto
    // (ver MyPostsView.swift).
    @State private var showMyPosts = false
    // Hallazgo real: no había forma de editar nombre/bio/color de avatar
    // en ningún sitio (ver PerfilViewModel.updateBasicInfo).
    @State private var showEditProfile = false
    // Hallazgo real: "socials" (vínculo mutuo, el concepto de relación
    // central de la app) no tenía ninguna pantalla de lista en ninguna
    // plataforma, solo el número (ver SocialsListViewModel.swift).
    @State private var showSocialsList = false
    // Hallazgo real: guardar un post (icono de marcador en PostCard,
    // HomeViewModel.toggleSave) lleva varias pasadas guardando de verdad
    // en `saved_posts`, pero no había ninguna pantalla para ver lo
    // guardado (ver SavedPostsView.swift).
    @State private var showSavedPosts = false
    // Hallazgo real, comparado con Instagram/Twitter/TikTok: los
    // contadores "Siguiendo"/"Seguidores" ya eran reales, pero tocarlos no
    // hacía nada -- ver FollowListViewModel.swift.
    @State private var showFollowList = false
    @State private var followListInitialTab: FollowTab = .following
    // Reels (0050_reels.sql) -- primera vez que hay un acceso real, antes
    // ni siquiera existía la UI de cliente.
    @State private var showReels = false
    // "Pubs. de socials" (0051_post_social_tags.sql) -- reutiliza
    // MyPostsView con el filtro ya real "Con tus socials" en vez de
    // duplicar esa pantalla.
    @State private var showTaggedPosts = false
    // "En directo" (0056_live_streams.sql) -- último hueco grande de
    // SOCIAL_APP.html, ya no pendiente: motor real decidido por el
    // usuario (LiveKit Cloud).
    @State private var showLive = false
    @State private var currentUserID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    counters
                    // Hallazgo real: `viewModel.errorMessage` se rellena en
                    // `updateBasicInfo` (validación de longitud, fallo de
                    // red...) pero nada en esta vista lo mostraba nunca —
                    // a diferencia de PerfilScreen.kt (línea con
                    // `errorMessage?.let { Text(it) }`), que sí lo hacía. El
                    // sheet además se cierra sin esperar a que termine el
                    // `Task`, así que este mensaje es la única forma real de
                    // que el usuario se entere de que el guardado falló.
                    if let error = viewModel.errorMessage {
                        Text(error).foregroundColor(.red).font(.footnote)
                    }
                    Button("Editar perfil") { showEditProfile = true }
                        .buttonStyle(.bordered)
                    Button("Mi perfil completo") { showFullProfile = true }
                        .buttonStyle(.bordered)
                    Button("💬 Tus chats") { showChatList = true }
                        .buttonStyle(.bordered)
                    // Chats de grupo (0057_group_chats.sql) -- comparado
                    // con WhatsApp/Instagram/Messenger/Facebook, mismo
                    // criterio que "Tus chats": botón propio junto al 1:1,
                    // no mezclado en la rejilla de subsecciones.
                    Button("👥 Grupos") { showGroupChats = true }
                        .buttonStyle(.bordered)
                    subsectionsGrid
                }
                .padding()
            }
            .navigationTitle("Perfil")
            .toolbar {
                // Antes no existía ninguna pantalla de Ajustes en absoluto,
                // en ninguna plataforma, pese a que privacy_policy_es.md ya
                // prometía "borrado completo... desde Ajustes".
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAjustes = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task {
                if let id = try? await SupabaseManager.shared.client.auth.session.user.id {
                    currentUserID = id
                    await viewModel.load(userID: id)
                }
            }
            .sheet(isPresented: $showFullProfile) {
                FullProfileView(viewModel: viewModel)
            }
            .sheet(isPresented: $showEditProfile) {
                EditProfileView(
                    initialName: viewModel.profile?.displayName ?? "",
                    initialBio: viewModel.profile?.bio ?? "",
                    initialSkin: viewModel.profile?.avatarConfig?["skin"] ?? AvatarLook.skinTones[0],
                    initialHair: viewModel.profile?.avatarConfig?["hair"] ?? AvatarLook.hairTones[0],
                    initialTop: viewModel.profile?.avatarConfig?["top"] ?? AvatarLook.topColors[0],
                    initialUsername: viewModel.profile?.username ?? "",
                    usernameErrorMessage: viewModel.usernameErrorMessage,
                    onSave: { name, bio, skin, hair, top in
                        Task { await viewModel.updateBasicInfo(displayName: name, bio: bio, skin: skin, hair: hair, top: top) }
                    },
                    onSaveUsername: { username in
                        Task { await viewModel.updateUsername(username) }
                    }
                )
            }
            .sheet(isPresented: $showClothingStore) {
                ClothingStoreView()
            }
            .sheet(isPresented: $showAjustes) {
                NavigationStack {
                    AjustesView(onAccountDeleted: { showAjustes = false })
                }
            }
            .sheet(isPresented: $showDuelHistory) {
                DuelHistoryView()
            }
            .sheet(isPresented: $showMyPosts) {
                NavigationStack {
                    MyPostsView()
                }
            }
            .sheet(isPresented: $showSavedPosts) {
                NavigationStack {
                    SavedPostsView()
                }
            }
            .sheet(isPresented: $showSocialsList) {
                NavigationStack {
                    SocialsListView()
                }
            }
            .sheet(isPresented: $showFollowList) {
                NavigationStack {
                    FollowListView(initialTab: followListInitialTab)
                }
            }
            .sheet(isPresented: $showReels) {
                NavigationStack {
                    ReelsView()
                }
            }
            .sheet(isPresented: $showTaggedPosts) {
                NavigationStack {
                    MyPostsView(initialTaggedOnly: true)
                }
            }
            .sheet(isPresented: $showLive) {
                NavigationStack {
                    LiveStreamsView()
                }
            }
            .sheet(isPresented: $showGroupChats) {
                NavigationStack {
                    GroupChatsListView()
                }
            }
            .sheet(isPresented: $showChatList) {
                // `.navigationDestination(isPresented:)` en vez de
                // `(item:)`: la variante `(item:)` es exclusiva de iOS 17+,
                // no compilaría contra el deployment target real de este
                // proyecto (iOS 16, mismo límite ya documentado para
                // onChange(of:) en este archivo).
                NavigationStack {
                    ChatListView(onOpenChat: { chatID in
                        selectedChatID = chatID
                        showOpenedChat = true
                    })
                    .navigationDestination(isPresented: $showOpenedChat) {
                        if let selectedChatID, let currentUserID {
                            ChatView(chatID: selectedChatID, currentUserID: currentUserID)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            RotatingProfileHeaderImage(
                avatarConfig: viewModel.profile?.avatarConfig ?? [:],
                photoURL: viewModel.latestPostMediaURL,
                size: 96
            )
            // Hallazgo real: `isVerified` existía en el modelo pero nunca
            // se renderizaba como badge en ningún sitio de la app.
            HStack(spacing: 4) {
                Text(viewModel.profile?.displayName ?? "Tu nombre")
                    .font(.title3.bold())
                if viewModel.profile?.isVerified == true {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                }
            }
            // Nombre de usuario único real (@handle,
            // 0073_profile_username.sql), comparado con Instagram/
            // Twitter/TikTok -- distinto del nombre para mostrar, que sí
            // puede repetirse y cambiar libremente.
            if let username = viewModel.profile?.username {
                Text("@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let bio = viewModel.profile?.bio {
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var counters: some View {
        HStack(spacing: 28) {
            CounterView(label: "Pubs", value: viewModel.postCount)
            CounterView(label: "Siguiendo", value: viewModel.followingCount)
                .onTapGesture { followListInitialTab = .following; showFollowList = true }
            CounterView(label: "Seguidores", value: viewModel.followerCount)
                .onTapGesture { followListInitialTab = .followers; showFollowList = true }
            CounterView(label: "Socials", value: viewModel.socialCount)
                .onTapGesture { showSocialsList = true }
        }
    }

    /// Cada subsección lleva una acción real. "En directo" ya no queda
    /// pendiente -- motor real decidido por el usuario (LiveKit Cloud,
    /// 0056_live_streams.sql + LiveStreamsView.swift). Reels y "Pubs. de
    /// socials" ya eran reales desde rondas anteriores.
    private var subsections: [(String, String, () -> Void)] {
        [
            ("Avatar", "person.crop.circle", { showClothingStore = true }),
            ("Reels", "play.rectangle", { showReels = true }),
            ("Fights", "bolt.fill", { showDuelHistory = true }),
            ("Pubs. de socials", "person.2.square.stack", { showTaggedPosts = true }),
            ("En directo", "dot.radiowaves.left.and.right", { showLive = true }),
            ("Tus publicaciones", "square.grid.3x3", { showMyPosts = true }),
            ("Guardados", "bookmark.fill", { showSavedPosts = true })
        ]
    }

    private var subsectionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ForEach(subsections, id: \.0) { name, icon, action in
                Button(action: action) {
                    VStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.title2)
                        Text(name)
                            .font(.caption)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

private struct CounterView: View {
    let label: String
    let value: Int
    var body: some View {
        VStack {
            Text("\(value)").font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Las 15 secciones editables, cada una con su marca de público/privado.
private struct FullProfileView: View {
    @ObservedObject var viewModel: PerfilViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingKey: String?

    var body: some View {
        NavigationStack {
            List(PerfilViewModel.sectionKeys, id: \.self) { key in
                let section = viewModel.section(for: key)
                Button {
                    editingKey = key
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                                .foregroundStyle(.primary)
                            if let text = section?.content["texto"], !text.isEmpty {
                                Text(text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: (section?.isPublic ?? false) ? "eye" : "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Mi perfil completo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { editingKey.map { EditingSection(key: $0) } },
                set: { editingKey = $0?.key }
            )) { editing in
                SectionEditView(
                    key: editing.key,
                    existing: viewModel.section(for: editing.key),
                    onSave: { text, isPublic in
                        Task { await viewModel.saveSection(key: editing.key, text: text, isPublic: isPublic) }
                    }
                )
            }
        }
    }
}

private struct EditingSection: Identifiable {
    let key: String
    var id: String { key }
}

private struct SectionEditView: View {
    let key: String
    let existing: ProfileSection?
    let onSave: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var isPublic: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Escribe algo…", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                    // Hallazgo real, mismo criterio ya aplicado a
                    // caption/nombre/bio/detalles de denuncia: el límite
                    // de 2000 caracteres es real
                    // (profile_sections_texto_length,
                    // 0024_more_text_length_limits.sql) y ya se valida
                    // antes de guardar (PerfilViewModel.swift.saveSection),
                    // pero nada avisaba mientras se escribe. Mismo fix ya
                    // construido en la versión Kotlin equivalente.
                    Text("\(text.count)/2000")
                        .font(.caption2)
                        .foregroundStyle(text.count > 2000 ? .red : .secondary)
                }
                Section {
                    Toggle("Visible para todos", isOn: $isPublic)
                } footer: {
                    Text(isPublic
                         ? "Cualquiera puede ver esta sección en tu perfil."
                         : "Solo la verán las personas con las que tengas un social aceptado.")
                }
            }
            .navigationTitle(key.replacingOccurrences(of: "_", with: " ").capitalized)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        onSave(text, isPublic)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .onAppear {
            text = existing?.content["texto"] ?? ""
            isPublic = existing?.isPublic ?? false
        }
    }
}

/// Hallazgo real, comparado con SOCIAL_APP.html: la cabecera del perfil
/// alterna cada 3.5s entre el avatar y una foto real -- este comentario
/// ya prometía "avatar y foto alternándose" arriba en el encabezado del
/// archivo, pero nunca se implementó de verdad hasta esta pasada. Sin una
/// tabla de "foto de perfil" propia, la fuente honesta más cercana es la
/// última publicación real con foto (`PerfilViewModel.latestPostMediaURL`)
/// -- si no hay ninguna, se queda solo con el avatar, sin fingir una
/// rotación vacía. Equivalente de RotatingProfileHeaderImage
/// (PerfilScreen.kt).
private struct RotatingProfileHeaderImage: View {
    let avatarConfig: [String: String]
    let photoURL: URL?
    let size: CGFloat
    @State private var showAvatar = true

    var body: some View {
        if photoURL == nil {
            ActiveAvatarProvider.shared.avatarView(config: avatarConfig, size: size)
        } else {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if showAvatar {
                        ActiveAvatarProvider.shared.avatarView(config: avatarConfig, size: size)
                    } else if let photoURL {
                        AsyncImage(url: photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ActiveAvatarProvider.shared.avatarView(config: avatarConfig, size: size)
                        }
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                    }
                }
                .id(showAvatar)
                .transition(.opacity)

                Text(showAvatar ? "avatar" : "foto")
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(2)
            }
            .animation(.easeInOut, value: showAvatar)
            .onReceive(Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()) { _ in
                showAvatar.toggle()
            }
        }
    }
}
