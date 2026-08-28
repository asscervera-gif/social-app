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
    // Activar avisos de publicaciones de esta cuenta real ("🔔"),
    // comparado con Instagram/Twitter/X -- solo tiene sentido real una
    // vez que ya la sigues (mismo criterio real que esas apps: la
    // campana solo aparece tras seguir). Ver PostNotificationManager.swift,
    // 0098_post_notifications.sql.
    @State private var isSubscribedToPosts = false
    @State private var subscriptionBusy = false
    private let postNotificationManager = PostNotificationManager()
    // Hallazgo real, comparado con Instagram/Twitter/TikTok: el visor de
    // OTRA persona solo tenía "Seguir" -- ningún "Bloquear" ni "Denunciar"
    // directo, pese a que ReportSheet ya incluye ambas acciones reales
    // (ver SafetyToolbar.swift). El overlay global tiene un bug ya
    // documentado (sin target real en contexto, denuncia por defecto al
    // PROPIO usuario) -- aquí sí hay un target real, el sitio correcto.
    @State private var showReportSheet = false
    // Insignia real de cumpleaños (🎂), comparado con Instagram -- sin
    // cron, calculado al leer (respeta profiles.show_birthday). Ver
    // 0140_birthday.sql. Equivalente de ProfileViewerScreen.kt.
    @State private var isBirthdayToday = false

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
                    if isBirthdayToday {
                        Text("🎂")
                    }
                }
                // Nombre de usuario único real (@handle,
                // 0073_profile_username.sql), comparado con Instagram/
                // Twitter/TikTok -- desambigua cuando dos personas
                // comparten nombre para mostrar.
                if let username = profile?.username {
                    Text("@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let bio = profile?.bio {
                    Text(bio).foregroundStyle(.secondary)
                }
                // Enlace externo real en el perfil ("link in bio",
                // 0077_profile_website.sql), comparado con Instagram/
                // TikTok/Twitter.
                if let websiteURLString = profile?.websiteURL, let url = URL(string: websiteURLString) {
                    Link(websiteURLString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""), destination: url)
                        .font(.subheadline)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                // Destacados reales de historias en el perfil, comparado
                // con Instagram -- misma fila que en el propio perfil
                // (PerfilView.swift), ver StoryHighlightsRow.swift/
                // 0101_story_highlights.sql.
                StoryHighlightsRow(profileID: profileID)

                // Hallazgo real: no había ningún botón "Seguir" directo en
                // este visor, solo "seguir de vuelta" desde una
                // notificación — ver FollowManager.swift para el detalle.
                if let myID, myID != profileID {
                    let toggleFollow = {
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
                    // Hallazgo real (CI real): `.buttonStyle(cond ? .bordered
                    // : .borderedProminent)` no compila — un ternario exige
                    // que ambas ramas sean el MISMO tipo concreto, y
                    // `.bordered`/`.borderedProminent` son tipos opacos
                    // distintos (BorderedButtonStyle/BorderedProminentButtonStyle),
                    // no miembros intercambiables de ButtonStyle en sí.
                    if isFollowing {
                        Button("Siguiendo", action: toggleFollow)
                            .buttonStyle(.bordered)
                            .disabled(followBusy)
                    } else {
                        Button("Seguir", action: toggleFollow)
                            .buttonStyle(.borderedProminent)
                            .disabled(followBusy)
                    }
                    // Activar avisos de publicaciones de esta cuenta real
                    // ("🔔"), comparado con Instagram/Twitter/X -- solo
                    // aparece una vez que ya la sigues.
                    if isFollowing {
                        Button(isSubscribedToPosts ? "🔔" : "🔕") {
                            subscriptionBusy = true
                            Task {
                                if isSubscribedToPosts {
                                    _ = await postNotificationManager.unsubscribe(subscriberID: myID, creatorID: profileID)
                                } else {
                                    _ = await postNotificationManager.subscribe(subscriberID: myID, creatorID: profileID)
                                }
                                isSubscribedToPosts.toggle()
                                subscriptionBusy = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(subscriptionBusy)
                    }
                    Button("⚠") { showReportSheet = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
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
        .sheet(isPresented: $showReportSheet) {
            if let myID {
                ReportSheet(userID: myID, reportedID: profileID)
            }
        }
        .task {
            // Hallazgo real (CI real, GitHub Actions): `client` estaba
            // declarado dentro del `do { }` y se usaba también fuera de
            // él más abajo — fuera de alcance, no compilaba.
            let client = SupabaseManager.shared.client
            do {
                profile = try await client.from("profiles").select().eq("id", value: profileID).single().execute().value
                sections = try await client.from("profile_sections").select().eq("profile_id", value: profileID).execute().value
            } catch {
                errorMessage = "No se pudo cargar el perfil."
            }

            isBirthdayToday = (try? await client
                .rpc("is_birthday_today", params: BirthdayTodayParams(p_profile_id: profileID))
                .execute()
                .value) ?? false

            myID = try? await client.auth.session.user.id
            if let myID, myID != profileID {
                isFollowing = await followManager.isFollowing(followerID: myID, followeeID: profileID)
                isSubscribedToPosts = await postNotificationManager.isSubscribed(subscriberID: myID, creatorID: profileID)
                // "Quién visitó tu perfil" real, comparado con LinkedIn/
                // Twitter-X (Premium) -- ver ProfileVisitsView.swift,
                // 0132_profile_visits.sql. Se registra en segundo plano,
                // sin bloquear la carga del perfil ni avisar de un fallo
                // (no es una acción crítica para el visitante).
                struct NewProfileVisit: Encodable {
                    let visitor_id: UUID
                    let visited_id: UUID
                    let visited_at: String
                }
                try? await client
                    .from("profile_visits")
                    .upsert(
                        NewProfileVisit(visitor_id: myID, visited_id: profileID, visited_at: ISO8601DateFormatter().string(from: Date())),
                        onConflict: "visitor_id,visited_id"
                    )
                    .execute()
            }
        }
    }
}

// Insignia real de cumpleaños (🎂), comparado con Instagram -- ver
// is_birthday_today() (0140_birthday.sql).
private struct BirthdayTodayParams: Encodable { let p_profile_id: UUID }
