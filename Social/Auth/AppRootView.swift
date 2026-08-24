//
//  AppRootView.swift
//  Social
//
//  Punto de entrada real que faltaba en TODA la sesión: SocialApp.swift
//  mostraba RootTabView siempre, sin comprobar si había una sesión real —
//  cualquiera que abriera la app entraba directo, sin cuenta. Reactivo a
//  `authStateChanges` (no una comprobación puntual): si la sesión expira o
//  se cierra, vuelve a AuthView sin tener que matar el proceso.
//  Equivalente de AppRoot.kt.
//
//  Aviso de honestidad: `for await state in client.auth.authStateChanges`
//  es la forma documentada de supabase-swift 2.x para observar sesión en
//  vivo, coherente con `client.auth.session.user.id` ya usado (y
//  compiler-verificado indirectamente en Android vía el mismo patrón
//  conceptual `sessionStatus`) en el resto del proyecto — sin verificación
//  de compilador real aquí (límite de plataforma).
//

import SwiftUI
import Supabase
import UserNotifications

struct AppRootView: View {
    @State private var isAuthenticated: Bool?
    // Hallazgo real, hueco grande documentado toda la sesión:
    // SelfieConsentView/generateAvatar estaban construidos pero nunca se
    // llamaban desde ningún sitio — se dispara aquí, una vez, cuando el
    // perfil recién autenticado todavía no tiene avatar_config.
    @State private var showAvatarOnboarding = false

    var body: some View {
        Group {
            // Hallazgo real (CI real, GitHub Actions): switch sobre un
            // Bool? con patrones literales `true`/`false`/`nil` no lo
            // reconoce el comprobador de exhaustividad de Swift como
            // exhaustivo (usa el operador de coincidencia de expresiones,
            // no los casos canónicos .some/.none) — necesita un `default`
            // aunque los 3 casos ya cubran toda la realidad.
            switch isAuthenticated {
            case true:
                RootTabView()
                    .sheet(isPresented: $showAvatarOnboarding) {
                        OnboardingAvatarView(onFinished: { showAvatarOnboarding = false })
                    }
            case false:
                AuthView()
            default:
                ProgressView()
            }
        }
        .task {
            let session = try? await SupabaseManager.shared.client.auth.session
            isAuthenticated = session != nil
            if session != nil { await checkNeedsAvatarOnboarding() }

            for await state in SupabaseManager.shared.client.auth.authStateChanges {
                let wasAuthenticated = isAuthenticated == true
                isAuthenticated = state.session != nil
                if !wasAuthenticated && state.session != nil {
                    await checkNeedsAvatarOnboarding()
                }
                // Hallazgo real: al cerrar sesión, el número rojo del
                // icono de la app (y cualquier notificación local
                // pendiente) se quedaba con los avisos de la cuenta que
                // se acaba de cerrar — un usuario distinto que inicie
                // sesión en el mismo dispositivo vería un badge ajeno
                // hasta el próximo evento de Realtime.
                if wasAuthenticated && state.session == nil {
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                }
            }
        }
    }

    private func checkNeedsAvatarOnboarding() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct AvatarConfigRow: Decodable { let avatar_config: [String: String]? }
        let row: AvatarConfigRow? = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("avatar_config")
            .eq("id", value: userID)
            .single()
            .execute()
            .value
        showAvatarOnboarding = row?.avatar_config == nil
    }
}
