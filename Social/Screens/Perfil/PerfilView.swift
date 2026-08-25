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
                    onSave: { name, bio, skin, hair, top in
                        Task { await viewModel.updateBasicInfo(displayName: name, bio: bio, skin: skin, hair: hair, top: top) }
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
            ActiveAvatarProvider.shared.avatarView(config: viewModel.profile?.avatarConfig ?? [:], size: 96)
            // Hallazgo real: `isVerified` existía en el modelo pero nunca
            // se renderizaba como badge en ningún sitio de la app.
            HStack(spacing: 4) {
                Text(viewModel.profile?.displayName ?? "Tu nombre")
                    .font(.title3.bold())
                if viewModel.profile?.isVerified == true {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                }
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
            CounterView(label: "Seguidores", value: viewModel.followerCount)
            CounterView(label: "Socials", value: viewModel.socialCount)
                .onTapGesture { showSocialsList = true }
        }
    }

    /// Cada subsección lleva una acción; las que aún no tienen pantalla propia
    /// (Reels, Fights, Pubs. de socials, En directo, Tus publicaciones) quedan
    /// pendientes de las fases correspondientes y no fingen tener contenido.
    // "Fights" y "Tus publicaciones" ya son reales (usan `duels`/`posts`,
    // sin infraestructura nueva). Reels/Pubs. de socials/En directo siguen
    // vacíos a propósito: necesitarían Supabase Storage real para
    // fotos/vídeo, mismo bloqueo que Historias y el chat multimedia — no
    // fingido aquí.
    private var subsections: [(String, String, () -> Void)] {
        [
            ("Avatar", "person.crop.circle", { showClothingStore = true }),
            ("Reels", "play.rectangle", {}),
            ("Fights", "bolt.fill", { showDuelHistory = true }),
            ("Pubs. de socials", "person.2.square.stack", {}),
            ("En directo", "dot.radiowaves.left.and.right", {}),
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
