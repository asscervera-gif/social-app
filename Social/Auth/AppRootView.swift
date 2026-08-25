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
    // Hallazgo real: ninguna plataforma explicaba qué es o cómo funciona
    // la detección UWB antes de soltar al usuario en la cámara —
    // comparado con cualquier app grande (Instagram/TikTok/Snapchat, que
    // sí muestran un carrusel de bienvenida), un hueco real de
    // onboarding. Se muestra una sola vez por dispositivo, encima de
    // RootTabView, la primera vez que hay sesión real.
    @State private var showHowItWorks = false
    // Hallazgo real, encontrado comparando con AppRoot.kt (que SÍ lo
    // tiene desde una pasada anterior): un admin ya podía banear desde
    // ModerationView, pero nada del lado del cliente iOS comprobaba
    // nunca si TU PROPIA cuenta estaba baneada — un usuario baneado
    // seguía entrando a la app con normalidad, el baneo solo existía en
    // la base de datos sin ningún efecto real en esta plataforma. Mismo
    // hueco de confianza y seguridad que growth_strategy.md llama "el
    // requisito de adopción más alto, no una función secundaria".
    @State private var isBanned = false
    @State private var banReason: String?

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
                if isBanned {
                    BannedView(reason: banReason, onSignOut: {
                        Task { try? await SupabaseManager.shared.client.auth.signOut() }
                    })
                } else {
                    RootTabView()
                        .sheet(isPresented: $showAvatarOnboarding) {
                            OnboardingAvatarView(onFinished: { showAvatarOnboarding = false })
                        }
                        .fullScreenCover(isPresented: $showHowItWorks) {
                            HowItWorksView(onFinished: { showHowItWorks = false })
                        }
                }
            case false:
                AuthView()
            default:
                ProgressView()
            }
        }
        .task {
            // Bypass exclusivo de CI, para poder capturar una pantalla
            // real de RootTabView (Home/Match/etc.) en el workflow de
            // GitHub Actions — el Config.plist de relleno de CI nunca
            // consigue una sesión real, así que sin esto la captura
            // automática nunca pasaría de Auth/Welcome. Solo se activa si
            // el proceso lanzado lleva la variable de entorno explícita
            // (ver .github/workflows/build.yml) — no hay forma de
            // activarlo desde fuera de un lanzamiento de CI controlado.
            if ProcessInfo.processInfo.environment["CI_SKIP_AUTH"] == "1" {
                isAuthenticated = true
                return
            }

            let session = try? await SupabaseManager.shared.client.auth.session
            isAuthenticated = session != nil
            if session != nil {
                await checkBanStatus()
                await checkNeedsAvatarOnboarding()
                showHowItWorks = !HowItWorksSeen.value
                PushTokenManager.requestAuthorizationAndRegister()
            }

            for await state in SupabaseManager.shared.client.auth.authStateChanges {
                let wasAuthenticated = isAuthenticated == true
                isAuthenticated = state.session != nil
                if !wasAuthenticated && state.session != nil {
                    await checkBanStatus()
                    await checkNeedsAvatarOnboarding()
                    showHowItWorks = !HowItWorksSeen.value
                    PushTokenManager.requestAuthorizationAndRegister()
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

    private func checkBanStatus() async {
        struct BanStatusRow: Decodable {
            let is_currently_banned: Bool
            let ban_reason: String?
        }
        // Si falla la comprobación (red, etc.), no se bloquea a un
        // usuario legítimo — mismo criterio que checkNeedsAvatarOnboarding
        // y que AppRoot.kt.
        guard let row: BanStatusRow = try? await SupabaseManager.shared.client
            .from("my_ban_status")
            .select()
            .single()
            .execute()
            .value
        else {
            isBanned = false
            return
        }
        isBanned = row.is_currently_banned
        banReason = row.ban_reason
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

/// Pantalla de bloqueo real cuando `my_ban_status.is_currently_banned` es
/// true — hasta esta pasada, un usuario baneado por un admin en
/// ModerationView seguía usando la app iOS con total normalidad, el
/// baneo solo existía como una fila en la base de datos sin ningún
/// efecto. Equivalente de BannedScreen en AppRoot.kt.
private struct BannedView: View {
    let reason: String?
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Cuenta suspendida").font(.title2.bold())
            Text(reason ?? "Tu cuenta ha sido suspendida por incumplir las normas de la comunidad.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Cerrar sesión", action: onSignOut)
                .buttonStyle(.borderedProminent)
                .padding(.top, 12)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
