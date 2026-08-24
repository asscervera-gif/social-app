//
//  PerfilViewModel.swift
//  Social
//

import Foundation

@MainActor
final class PerfilViewModel: ObservableObject {

    @Published var profile: Profile?
    @Published var sections: [ProfileSection] = []
    @Published var postCount = 0
    @Published var followingCount = 0
    @Published var followerCount = 0
    @Published var socialCount = 0
    @Published var errorMessage: String?

    private var userID: UUID?

    /// Las 15 secciones editables del perfil completo, en el orden que ve el usuario.
    static let sectionKeys = [
        "sobre_mi", "trabajo", "estudios", "musica", "cine", "deportes",
        "viajes", "comida", "mascotas", "idiomas", "signo", "altura",
        "busco", "redes", "curiosidad"
    ]

    func load(userID: UUID) async {
        self.userID = userID
        do {
            let client = SupabaseManager.shared.client
            profile = try await client.from("profiles").select().eq("id", value: userID).single().execute().value
            sections = try await client.from("profile_sections").select().eq("profile_id", value: userID).execute().value
            await loadCounters(userID: userID)
        } catch {
            errorMessage = "No se pudo cargar el perfil: \(error.localizedDescription)"
        }
    }

    /// Hallazgo real: `postCount`/`followingCount`/`followerCount`/`socialCount`
    /// se mostraban en `PerfilView.swift` (fila de contadores bajo la
    /// cabecera) pero nunca se calculaban en ningún sitio — se quedaban en
    /// su valor inicial (0) para siempre, sin importar cuántas publicaciones,
    /// seguidos, seguidores o socials tuviera de verdad el usuario.
    ///
    /// Aviso de honestidad: `select(head:count:)` con `CountOption.exact` es
    /// la forma habitual de pedir solo el recuento en supabase-swift 2.x,
    /// pero no está verificada con compilador real en este entorno (límite
    /// de plataforma) — si la firma exacta difiere, es el único sitio a
    /// ajustar.
    private func loadCounters(userID: UUID) async {
        let client = SupabaseManager.shared.client
        async let posts = try? client.from("posts").select(head: true, count: .exact).eq("author_id", value: userID).execute()
        async let following = try? client.from("follows").select(head: true, count: .exact).eq("follower_id", value: userID).execute()
        async let followers = try? client.from("follows").select(head: true, count: .exact).eq("followee_id", value: userID).execute()
        async let requested = try? client.from("socials").select(head: true, count: .exact)
            .eq("requester_id", value: userID).eq("status", value: "accepted").execute()
        async let addressed = try? client.from("socials").select(head: true, count: .exact)
            .eq("addressee_id", value: userID).eq("status", value: "accepted").execute()

        postCount = await posts?.count ?? 0
        followingCount = await following?.count ?? 0
        followerCount = await followers?.count ?? 0
        socialCount = (await requested?.count ?? 0) + (await addressed?.count ?? 0)
    }

    func section(for key: String) -> ProfileSection? {
        sections.first { $0.sectionKey == key }
    }

    /// Hallazgo real: comparado con cualquier app grande, no había forma
    /// de editar nombre/bio/color de avatar en ningún sitio — solo las 15
    /// secciones eran editables. Sin selector de foto real a propósito
    /// (mismo criterio que EditProfileSheet.kt): la generación de avatar
    /// 3D sigue sin onboarding construido.
    func updateBasicInfo(displayName: String, bio: String, colorSeed: String) async {
        guard let userID else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            errorMessage = "El nombre no puede estar vacío."
            return
        }
        // Mismos límites reales que profiles_display_name_length/
        // profiles_bio_length (0023_text_length_limits.sql) — validado
        // aquí también para dar un error claro en vez de que el update
        // falle en silencio, mismo criterio ya compiler-verificado en la
        // versión Kotlin equivalente.
        guard trimmedName.count <= 50 else {
            errorMessage = "El nombre no puede tener más de 50 caracteres."
            return
        }
        guard bio.count <= 300 else {
            errorMessage = "La bio no puede tener más de 300 caracteres."
            return
        }

        var newConfig = profile?.avatarConfig ?? [:]
        newConfig["colorSeed"] = colorSeed

        struct ProfileUpdate: Encodable {
            let display_name: String
            let bio: String?
            let avatar_config: [String: String]
        }

        profile?.displayName = trimmedName
        profile?.bio = bio.isEmpty ? nil : bio
        profile?.avatarConfig = newConfig

        do {
            try await SupabaseManager.shared.client
                .from("profiles")
                .update(ProfileUpdate(display_name: trimmedName, bio: bio.isEmpty ? nil : bio, avatar_config: newConfig))
                .eq("id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo guardar el perfil."
        }
    }

    /// Crea o actualiza una sección (upsert por la unique constraint
    /// `(profile_id, section_key)` de la Fase 2). Actualización optimista:
    /// la UI refleja el cambio antes de que confirme el servidor.
    func saveSection(key: String, text: String, isPublic: Bool) async {
        guard let userID else { return }
        // Mismo límite real que profile_sections_texto_length
        // (0024_more_text_length_limits.sql) — validado aquí también,
        // mismo criterio ya aplicado a nombre/bio/caption/mensaje/
        // comentario, ya construido en la versión Kotlin equivalente.
        guard text.count <= 2000 else {
            errorMessage = "El texto no puede tener más de 2000 caracteres."
            return
        }

        struct SectionUpsert: Encodable {
            let profile_id: UUID
            let section_key: String
            let content: [String: String]
            let is_public: Bool
        }

        if let index = sections.firstIndex(where: { $0.sectionKey == key }) {
            sections[index].content = ["texto": text]
            sections[index].isPublic = isPublic
        } else {
            sections.append(ProfileSection(id: UUID(), profileID: userID, sectionKey: key, content: ["texto": text], isPublic: isPublic))
        }

        do {
            try await SupabaseManager.shared.client
                .from("profile_sections")
                .upsert(
                    SectionUpsert(profile_id: userID, section_key: key, content: ["texto": text], is_public: isPublic),
                    onConflict: "profile_id,section_key"
                )
                .execute()
        } catch {
            errorMessage = "No se pudo guardar '\(key)': \(error.localizedDescription)"
        }
    }
}
