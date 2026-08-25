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
    @StateObject private var account = AccountManager()
    // Hallazgo real: `compat_public`/`location_public` se consultaban en
    // Match/Home/"Find" pero no había ningún interruptor para activarlos
    // en ninguna plataforma (ver PrivacySettingsViewModel.swift).
    @StateObject private var privacy = PrivacySettingsViewModel()
    @State private var showConfirm = false
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
