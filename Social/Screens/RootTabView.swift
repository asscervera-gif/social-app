//
//  RootTabView.swift
//  Social
//
//  Cinco pestañas: Home, Match, Social (cámara, por defecto), Avisos, Perfil.
//  Sustituye a SocialCameraView como punto de entrada declarado en SocialApp.swift
//  a partir de la Fase 4.
//

import SwiftUI

struct RootTabView: View {

    @State private var selectedTab: Tab = .social
    // `SafetyManager` se mantiene inyectado (ReportSheet lo lee vía
    // @EnvironmentObject desde cualquier pantalla) -- solo se quitó el
    // botón flotante `SafetyToolbar` de aquí, ver el hallazgo real más
    // abajo en el body.
    @StateObject private var safety = SafetyManager()
    // Hallazgo real, comparado con Android (que ya tenía colores reales
    // del logo metidos a mano): iOS no tenía NINGÚN color de marca, usaba
    // el azul de sistema por defecto de SwiftUI en toda la app -- ver
    // Theme.swift/AjustesView.swift.
    @ObservedObject private var accent = AccentPreference.shared
    // Badge de no leídas en Avisos — mismo hallazgo que RootTabView.kt: no
    // había ninguna señal de "hay algo nuevo" sin entrar a mirar.
    @StateObject private var notificationsBadge = NotificationsBadgeViewModel()

    enum Tab {
        case home, match, social, avisos, perfil
    }

    var body: some View {
        // Hallazgo real, reportado directamente por el usuario probando
        // la app de verdad: "hay un icono de denunciar/bloquear que no sé
        // en qué momento está ahí" -- el botón flotante `SafetyToolbar`
        // ya solo abría un aviso de "denúncialo desde su perfil/chat/
        // post/comentario" (desde que se cerró el bug de autodenuncia),
        // porque cada pantalla real ya tiene su propio botón con el
        // target correcto. Un icono flotante que solo explica dónde ir
        // ya no aporta nada, solo confunde -- quitado del todo, no
        // sustituido por nada (SafetyManager/ReportSheet no dependen de
        // este overlay para funcionar).
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(Tab.home)

                MatchView()
                    // Hallazgo real, comparado con Instagram/Duolingo: el
                    // icono era una rejilla genérica sin relación con lo
                    // que hace la pestaña -- mismo cambio ya aplicado en
                    // Android (Icons.Filled.Favorite).
                    .tabItem { Label("Match", systemImage: "heart.fill") }
                    .tag(Tab.match)

                SocialCameraView()
                    .tabItem { SocialTabIcon() }
                    .tag(Tab.social)

                AvisosView()
                    .tabItem { Label("Avisos", systemImage: "bell.fill") }
                    .tag(Tab.avisos)
                    .badge(notificationsBadge.unreadCount)

                PerfilView()
                    .tabItem { Label("Perfil", systemImage: "person.crop.circle.fill") }
                    .tag(Tab.perfil)
            }
            .tint(accent.color)
        }
        .environmentObject(safety)
        .task {
            AnalyticsManager.track("app_open")
        }
        .task {
            await notificationsBadge.start()
        }
        // Hallazgo real: `RootTabView` desaparece por completo al cerrar
        // sesión (AppRootView.swift vuelve a AuthView), pero nada llamaba
        // nunca a `notificationsBadge.stop()` — el canal Realtime de la
        // cuenta que se acaba de cerrar se quedaba sin darse de baja
        // explícitamente, mismo patrón de limpieza que ya usa
        // ChatViewModel en el resto de la app.
        .onDisappear {
            Task { await notificationsBadge.stop() }
        }
        // El closure de un solo parámetro (newValue) es la firma de
        // onChange(of:) compatible con el deployment target real de este
        // proyecto (iOS 16, ver project.yml) — la forma de dos parámetros
        // (oldValue, newValue) es exclusiva de iOS 17+ y no compilaría aquí.
        .onChange(of: selectedTab) { _ in
            AnalyticsManager.track("tab_view")
        }
        // Hueco real, encontrado comparando con Instagram/TikTok/Snapchat:
        // tocar un aviso local no llevaba a ningún sitio -- ver
        // NotificationDelegate.swift/NotificationsBadgeViewModel.swift.
        .onReceive(NotificationCenter.default.publisher(for: .openAvisosTab)) { _ in
            selectedTab = .avisos
        }
    }
}

/// Icono de la pestaña Social: letra "S" fina con degradado multicolor,
/// tal como especifica el diseño de producto.
///
/// Hallazgo real: el comentario ya prometía un "degradado multicolor",
/// pero el código nunca lo aplicaba -- `Text("S")` sin ningún
/// `.foregroundStyle`, texto plano del color de tinte por defecto. Ahora
/// sí usa el degradado real del logo (social_logo.png, mismos colores que
/// SocialColors/Android) -- equivalente exacto del icono "S" ya corregido
/// en RootTabView.kt.
private struct SocialTabIcon: View {
    var body: some View {
        Label {
            Text("Social")
        } icon: {
            Text("S")
                .font(.system(size: 20, weight: .light, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            SocialColors.magenta, SocialColors.coral, SocialColors.orange,
                            SocialColors.gold, SocialColors.green, SocialColors.turquoise, SocialColors.purple
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                // Aviso de honestidad: UIKit renderiza el icono de
                // `.tabItem` como plantilla monocroma en algunas versiones
                // de iOS, lo que puede ignorar este degradado y mostrar
                // solo el tinte de acento -- límite conocido de la
                // plataforma, no verificable sin Simulador real en este
                // entorno. Si no se ve el degradado, el tinte de acento
                // (Theme.swift) sigue aplicándose igualmente.
        }
    }
}

#Preview {
    RootTabView()
}
