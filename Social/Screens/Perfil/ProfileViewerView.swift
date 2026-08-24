//
//  ProfileViewerView.swift
//  Social
//
//  Visor de perfil de solo lectura para OTRA persona (no el propio) —
//  reutiliza el mismo patrón de carga que PerfilViewModel pero sin edición.
//  Antes "Ver perfil" en AvisosView.swift era un botón vacío (`{}`), sin
//  ningún visor genérico al que llevar.
//

import SwiftUI

struct ProfileViewerView: View {
    let profileID: UUID

    @State private var profile: Profile?
    @State private var sections: [ProfileSection] = []
    @State private var errorMessage: String?
    @State private var myID: UUID?
    @State private var isFollowing = false
    @State private var followBusy = false
    @StateObject private var followManager = FollowManager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Hallazgo real: este visor nunca pintaba el avatar, a
                // diferencia de PerfilView/HomeView/MatchView.
                ActiveAvatarProvider.shared.avatarView(config: profile?.avatarConfig ?? [:], size: 80)
                // Hallazgo real: `isVerified` existía en el modelo pero
                // nunca se renderizaba como badge en ningún sitio.
                HStack(spacing: 4) {
                    Text(profile?.displayName ?? "Perfil")
                        .font(.title2.bold())
                    if profile?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue)
                    }
                }
                if let bio = profile?.bio {
                    Text(bio).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                // Hallazgo real: no había ningún botón "Seguir" directo en
                // este visor, solo "seguir de vuelta" desde una
                // notificación — ver FollowManager.swift para el detalle.
                if let myID, myID != profileID {
                    Button(isFollowing ? "Siguiendo" : "Seguir") {
                        followBusy = true
                        Task {
                            if isFollowing {
                                await followManager.unfollow(followerID: myID, followeeID: profileID)
                            } else {
                                await followManager.follow(followerID: myID, followeeID: profileID)
                            }
                            isFollowing.toggle()
                            followBusy = false
                        }
                    }
                    .buttonStyle(isFollowing ? .bordered : .borderedProminent)
                    .disabled(followBusy)
                }

                // Solo se muestran las secciones marcadas como públicas —
                // este es el visor de OTRA persona, no el propio editor.
                ForEach(sections.filter { $0.isPublic }) { section in
                    if let text = section.content["texto"], !text.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.sectionKey.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(text)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Perfil")
        .task {
            do {
                let client = SupabaseManager.shared.client
                profile = try await client.from("profiles").select().eq("id", value: profileID).single().execute().value
                sections = try await client.from("profile_sections").select().eq("profile_id", value: profileID).execute().value
            } catch {
                errorMessage = "No se pudo cargar el perfil."
            }

            myID = try? await client.auth.session.user.id
            if let myID, myID != profileID {
                isFollowing = await followManager.isFollowing(followerID: myID, followeeID: profileID)
            }
        }
    }
}
