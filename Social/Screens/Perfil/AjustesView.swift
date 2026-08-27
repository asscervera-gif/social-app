//
//  AjustesView.swift
//  Social
//
//  Pantalla de Ajustes — antes no existía ninguna en absoluto, en ninguna
//  plataforma, a pesar de que `privacy_policy_es.md` ya prometía "borrado
//  completo de tu perfil... desde Ajustes". Confirmación de dos pasos antes
//  de un borrado irreversible. Equivalente de AjustesScreen.kt.
//

import SwiftUI

struct AjustesView: View {
    /// Categorías visibles en Ajustes -> valores reales de `notifications.kind`
    /// que agrupa cada una -- mismos valores exactos que
    /// AvisosViewModel.swift.icon()/title() y send-push/index.ts.
    /// Equivalente de NOTIFICATION_CATEGORIES (AjustesScreen.kt).
    // Hallazgo real (0058_group_message_notify.sql): "comment_like"/
    // "reel_comment_like" (0054_comment_likes.sql, varias rondas atrás)
    // nunca se añadieron a ninguna categoría -- silenciar "Me gusta" no
    // silenciaba en realidad el like a un comentario, solo el like a la
    // publicación entera. "group_message" (0057_group_chats.sql) añadido
    // a "Mensajes". "mention" (0074_mentions.sql) en su propia categoría
    // -- comparado con Instagram, que también deja silenciar menciones
    // por separado de comentarios normales.
    static let notificationCategories: [(String, [String])] = [
        ("Mensajes", ["message", "group_message"]),
        ("Me gusta", ["like", "reel_like", "comment_like", "reel_comment_like"]),
        ("Comentarios", ["comment", "reel_comment"]),
        ("Menciones", ["mention"]),
        ("Socials", ["social", "social_accepted"]),
        ("Seguidores", ["follow"]),
        // Activar avisos de publicaciones de una cuenta real ("🔔"),
        // comparado con Instagram/Twitter/X -- ver ProfileViewerView.swift,
        // 0098_post_notifications.sql.
        ("Publicaciones nuevas", ["new_post"]),
        ("Duelos", ["fight"]),
        ("Compatibilidad", ["compat_request", "compat_accepted"])
    ]

    @StateObject private var account = AccountManager()
    // Hallazgo real: `compat_public`/`location_public` se consultaban en
    // Match/Home/"Find" pero no había ningún interruptor para activarlos
    // en ninguna plataforma (ver PrivacySettingsViewModel.swift).
    @StateObject private var privacy = PrivacySettingsViewModel()
    @State private var showConfirm = false
    // Palabras silenciadas reales en comentarios (0078_muted_keywords.sql),
    // comparado con Instagram/Twitter.
    @State private var newMutedKeyword = ""
    // Verificación real (insignia azul, 0080_verification_requests.sql),
    // comparado con Instagram/Twitter/TikTok.
    @StateObject private var verification = VerificationRequestViewModel()
    @State private var verificationMessage = ""
    // Hallazgo real: `reports` ya recibía denuncias reales desde hace
    // muchas pasadas, pero nadie podía leerlas nunca sin una clave
    // privilegiada — `is_admin` (0036_admin_moderation.sql) es una
    // columna protegida por trigger, igual que `is_verified`, nunca
    // autoconcedible por el cliente. Este enlace solo aparece si la
    // consulta real a `profiles` confirma `is_admin = true`.
    @State private var isAdmin = false
    let onAccountDeleted: () -> Void
    // Hallazgo real, comparado con cualquier app grande: no había ninguna
    // forma de personalizar el color de acento -- solo el coral por
    // defecto, y Android ni siquiera tenía uno consistente hasta esta
    // pasada. Los siete colores son los reales del arcoíris del wordmark
    // del logo (ver Theme.swift), no inventados.
    @ObservedObject private var accent = AccentPreference.shared
    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp/TikTok/
    // Facebook: no había ninguna forma explícita de elegir modo oscuro --
    // ver Theme.swift.
    @ObservedObject private var themeMode = ThemeModePreference.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = account.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Text("Apariencia").font(.headline)
            HStack(spacing: 12) {
                ForEach(SocialColors.accents) { entry in
                    let selected = entry.key == accent.accentKey
                    Circle()
                        .fill(entry.color)
                        .frame(width: selected ? 36 : 28, height: selected ? 36 : 28)
                        .overlay(
                            Circle().stroke(.primary, lineWidth: selected ? 2 : 0)
                        )
                        .onTapGesture { accent.accentKey = entry.key }
                }
            }

            Text("Tema").font(.headline)
            Picker("Tema", selection: $themeMode.mode) {
                Text("Sistema").tag("system")
                Text("Claro").tag("light")
                Text("Oscuro").tag("dark")
            }
            .pickerStyle(.segmented)

            // Hallazgo real, comparado con Instagram/Twitter/Facebook/
            // WhatsApp: todas dejan silenciar "me gusta" sin silenciar
            // "mensajes" -- esta app solo tenía silenciar un CHAT
            // completo, nunca una CATEGORÍA de aviso. Se aplica de verdad
            // en el servidor (send-push/index.ts), no solo en el cliente.
            Text("Notificaciones").font(.headline)
            ForEach(Self.notificationCategories, id: \.0) { label, kinds in
                Toggle(isOn: Binding(
                    get: { !kinds.contains(where: { privacy.mutedKinds.contains($0) }) },
                    set: { enabled in privacy.setCategoryMuted(kinds, muted: !enabled) }
                )) {
                    Text(label)
                }
            }

            // Verificación real (insignia azul,
            // 0080_verification_requests.sql), comparado con
            // Instagram/Twitter/TikTok -- las tres dejan SOLICITAR la
            // verificación; un equipo revisa y aprueba o rechaza.
            // `is_verified` ya se pintaba de verdad en varias pantallas,
            // pero no existía ningún camino real para llegar a `true`
            // salvo escribirlo a mano en la base de datos.
            Text("Verificación").font(.headline)
            if let error = verification.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let success = verification.successMessage {
                Text(success).font(.caption).foregroundStyle(.green)
            }
            if verification.isVerified {
                Text("Tu cuenta ya está verificada ✔️").font(.subheadline)
            } else if verification.hasOpenRequest {
                Text("Tienes una solicitud de verificación pendiente de revisión.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                TextField("¿Por qué debería verificarse tu cuenta?", text: $verificationMessage, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Solicitar verificación") {
                    Task { await verification.submitRequest(verificationMessage) }
                }
                .buttonStyle(.bordered)
                .disabled(verificationMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Palabras silenciadas reales en comentarios
            // (0078_muted_keywords.sql), comparado con Instagram/Twitter
            // -- oculta automáticamente cualquier comentario propio
            // (post o reel) que contenga una de estas palabras, sin
            // bloquear a nadie: el comentario sigue existiendo de verdad
            // para todos los demás, incluido quien lo escribió.
            Text("Palabras silenciadas").font(.headline)
            Text("Oculta comentarios que contengan estas palabras, solo para ti.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("nueva palabra", text: $newMutedKeyword)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                Button("Añadir") {
                    privacy.addMutedKeyword(newMutedKeyword)
                    newMutedKeyword = ""
                }
                .disabled(newMutedKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(privacy.mutedKeywords, id: \.self) { word in
                HStack {
                    Text(word)
                    Spacer()
                    Button("Quitar", role: .destructive) {
                        privacy.removeMutedKeyword(word)
                    }
                    .font(.caption)
                }
            }

            Text("Privacidad").font(.headline)
            Toggle(isOn: Binding(
                get: { privacy.compatPublic },
                set: { privacy.setCompatPublic($0) }
            )) {
                VStack(alignment: .leading) {
                    Text("Compatibilidad pública")
                    Text("Deja que cualquiera vea tu % de compatibilidad sin tener que pedirlo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(
                get: { privacy.locationPublic },
                set: { privacy.setLocationPublic($0) }
            )) {
                VStack(alignment: .leading) {
                    Text("Ubicación pública")
                    Text("Muestra tu ubicación en el mapa de \"Find\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Recibo de lectura real ("Leído ✓✓"), comparado con WhatsApp/
            // Instagram/Messenger -- criterio recíproco real: si lo
            // apagas, tampoco ves el de los demás (ver
            // ChatViewModel.swift.showReadReceipts, 0091).
            Toggle(isOn: Binding(
                get: { privacy.readReceiptsEnabled },
                set: { privacy.setReadReceiptsEnabled($0) }
            )) {
                VStack(alignment: .leading) {
                    Text("Recibos de lectura")
                    Text("Muestra \"Leído ✓✓\" a los demás. Si lo apagas, tampoco verás el suyo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Hallazgo real: mismo patrón que socials — una vez aceptada
            // una compat_request, no había NINGUNA forma de revocar el
            // acceso a tu % de compatibilidad (ver CompatSharesView.swift).
            NavigationLink("Quién ve tu compatibilidad") {
                CompatSharesView()
            }
            .buttonStyle(.bordered)

            // Hallazgo real: bloquear era permanente — SafetyManager.block()
            // existía pero no había forma de ver ni deshacer un bloqueo (ver
            // BlockedUsersViewModel/View).
            NavigationLink("Usuarios bloqueados") {
                BlockedUsersView()
            }
            .buttonStyle(.bordered)

            // Restringir una cuenta real, comparado con Instagram --
            // deliberadamente más suave que bloquear (arriba): sus
            // comentarios dejan de verse para los demás sin que se
            // entere de nada. Ver SafetyManager.restrict()/
            // SafetyToolbar.swift, RestrictedUsersViewModel/View,
            // 0093_restrict_account.sql.
            NavigationLink("Cuentas restringidas") {
                RestrictedUsersView()
            }
            .buttonStyle(.bordered)

            // Hallazgo real de seguridad, comparado con Instagram/
            // Snapchat: `stories_select` no tenía NINGUNA restricción de
            // audiencia -- cualquiera veía la historia de cualquiera. Ver
            // CloseFriendsViewModel.swift.
            NavigationLink("Mejores amigos") {
                CloseFriendsView()
            }
            .buttonStyle(.bordered)

            if isAdmin {
                NavigationLink("Moderación") {
                    ModerationView()
                }
                .buttonStyle(.bordered)
            }

            ChangePasswordSection()

            // Hallazgo real, legalmente relevante: la política de
            // privacidad existía como documento del repositorio pero
            // nunca se mostraba dentro de la app.
            NavigationLink("Política de privacidad") {
                PrivacyPolicyView()
            }
            .buttonStyle(.bordered)

            NavigationLink("Términos de servicio") {
                TermsOfServiceView()
            }
            .buttonStyle(.bordered)

            // Hallazgo real: antes no había pantalla de login a la que
            // volver, así que ni siquiera tenía sentido un botón de cerrar
            // sesión — ya sí, con AuthView.swift/AppRootView.swift
            // reaccionando a authStateChanges.
            Button("Cerrar sesión") {
                Task { try? await SupabaseManager.shared.client.auth.signOut() }
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showConfirm = true
            } label: {
                if account.isDeleting {
                    ProgressView()
                } else {
                    Text("Borrar mi cuenta").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
        .navigationTitle("Ajustes")
        .alert("¿Borrar tu cuenta?", isPresented: $showConfirm) {
            Button("Borrar de verdad", role: .destructive) {
                Task {
                    if await account.deleteAccount() {
                        onAccountDeleted()
                    }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Esto borra tu perfil, publicaciones, mensajes, socials y todos los datos asociados de forma permanente. No se puede deshacer.")
        }
        .task { await privacy.load() }
        .task { await verification.load() }
        .task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            struct IsAdminRow: Decodable { let is_admin: Bool }
            let row: IsAdminRow? = try? await SupabaseManager.shared.client
                .from("profiles")
                .select("is_admin")
                .eq("id", value: userID)
                .single()
                .execute()
                .value
            isAdmin = row?.is_admin ?? false
        }
    }
}
