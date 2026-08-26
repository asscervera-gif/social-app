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
    // Nombre de usuario único real (@handle, 0073_profile_username.sql),
    // comparado con Instagram/Twitter/TikTok -- error aparte del genérico
    // de arriba, porque el fallo más probable (username ya en uso) tiene
    // un mensaje real y específico.
    @Published var usernameErrorMessage: String?
    // Hallazgo real, comparado con SOCIAL_APP.html: la cabecera del perfil
    // alterna cada 3.5s entre el avatar y una foto real -- sin una tabla
    // de "foto de perfil" propia, la fuente honesta más cercana es la
    // última publicación real con foto. Si no hay ninguna, la cabecera se
    // queda solo con el avatar, sin fingir una rotación vacía.
    @Published var latestPostMediaURL: URL?

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
            await loadLatestPostMedia(userID: userID)
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

    private struct MediaRow: Decodable { let media_url: String?; let archived_at: String? }

    /// Sin un filtro "is not null" verificado en supabase-swift, se piden
    /// las últimas 20 y se filtra en cliente -- mismo criterio de no
    /// adivinar una llamada de API no comprobada ya aplicado en el resto
    /// de esta sesión. Equivalente de PerfilViewModel.kt (latestPostMediaUrl).
    ///
    /// Archivar publicaciones real (0076_archive_posts.sql), comparado
    /// con Instagram/Facebook: una publicación archivada no debe seguir
    /// asomando en la rotación de la cabecera del propio perfil, mismo
    /// criterio ya aplicado al feed principal (HomeViewModel.swift).
    private func loadLatestPostMedia(userID: UUID) async {
        guard let rows: [MediaRow] = try? await SupabaseManager.shared.client
            .from("posts")
            .select("media_url,archived_at")
            .eq("author_id", value: userID)
            .order("created_at", ascending: false)
            .limit(20)
            .execute()
            .value else { return }
        latestPostMediaURL = rows.filter { $0.archived_at == nil }.compactMap { $0.media_url }.first.flatMap(URL.init)
    }

    /// Hallazgo real: comparado con cualquier app grande, no había forma
    /// de editar nombre/bio/look de avatar en ningún sitio — solo las 15
    /// secciones eran editables. Sin selector de foto real a propósito
    /// (mismo criterio que EditProfileSheet.kt): la generación de avatar
    /// 3D sigue sin un motor real (ver AvatarProvider). `skin`/`hair`/`top`
    /// (busto ilustrado, CartoonAvatarView) sustituyen al `colorSeed`
    /// único de antes de la pasada de fidelidad visual con SOCIAL_APP.html.
    func updateBasicInfo(displayName: String, bio: String, skin: String, hair: String, top: String, websiteURL: String) async {
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

        // Enlace externo real en el perfil ("link in bio",
        // 0077_profile_website.sql), comparado con Instagram/TikTok/
        // Twitter -- mismo criterio que username: normalización simple en
        // cliente (antepone "https://" si falta el esquema) en vez de una
        // validación estricta de URL. Límite real:
        // profiles_website_url_length. Equivalente de
        // PerfilViewModel.kt.updateBasicInfo().
        let trimmedWebsite = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWebsite: String?
        if trimmedWebsite.isEmpty {
            normalizedWebsite = nil
        } else if trimmedWebsite.hasPrefix("http://") || trimmedWebsite.hasPrefix("https://") {
            normalizedWebsite = trimmedWebsite
        } else {
            normalizedWebsite = "https://\(trimmedWebsite)"
        }
        if let normalizedWebsite, normalizedWebsite.count > 200 {
            errorMessage = "El enlace no puede tener más de 200 caracteres."
            return
        }

        var newConfig = profile?.avatarConfig ?? [:]
        newConfig["type"] = "cartoon"
        newConfig["skin"] = skin
        newConfig["hair"] = hair
        newConfig["top"] = top

        struct ProfileUpdate: Encodable {
            let display_name: String
            let bio: String?
            let avatar_config: [String: String]
            let website_url: String?
        }

        profile?.displayName = trimmedName
        profile?.bio = bio.isEmpty ? nil : bio
        profile?.avatarConfig = newConfig
        profile?.websiteURL = normalizedWebsite

        do {
            try await SupabaseManager.shared.client
                .from("profiles")
                .update(ProfileUpdate(display_name: trimmedName, bio: bio.isEmpty ? nil : bio, avatar_config: newConfig, website_url: normalizedWebsite))
                .eq("id", value: userID)
                .execute()
        } catch {
            errorMessage = "No se pudo guardar el perfil."
        }
    }

    /// Nombre de usuario único real (@handle, 0073_profile_username.sql),
    /// comparado con Instagram/Twitter/TikTok -- distinto del nombre para
    /// mostrar (`updateBasicInfo`), que sí puede repetirse y cambiar
    /// libremente. Comprueba disponibilidad con una consulta real ANTES
    /// de intentar guardar, en vez de un mensaje genérico si el guardado
    /// falla por cualquier motivo -- aviso de honestidad: no verificado
    /// en este entorno qué excepción concreta lanza supabase-swift ante
    /// una violación de `unique` real, así que no se intenta distinguirla
    /// adivinando su forma exacta. Mismo formato real que
    /// `profiles_username_format` (0073): minúsculas, dígitos y guión
    /// bajo, 3-20 caracteres, normalizado aquí antes de comprobar/guardar.
    /// Equivalente de PerfilViewModel.kt.updateUsername().
    func updateUsername(_ username: String) async {
        guard let userID else { return }
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        usernameErrorMessage = nil
        guard !normalized.isEmpty else { return }
        guard normalized.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil else {
            usernameErrorMessage = "El nombre de usuario debe tener 3-20 letras minúsculas, números o \"_\"."
            return
        }
        struct UsernameRow: Decodable { let id: UUID }
        struct UsernameUpdate: Encodable { let username: String }
        do {
            let existing: [UsernameRow] = try await SupabaseManager.shared.client
                .from("profiles")
                .select("id")
                .eq("username", value: normalized)
                .execute()
                .value
            if existing.contains(where: { $0.id != userID }) {
                usernameErrorMessage = "Ese nombre de usuario ya está en uso."
                return
            }
            try await SupabaseManager.shared.client
                .from("profiles")
                .update(UsernameUpdate(username: normalized))
                .eq("id", value: userID)
                .execute()
            profile?.username = normalized
        } catch {
            usernameErrorMessage = "No se pudo guardar el nombre de usuario."
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
