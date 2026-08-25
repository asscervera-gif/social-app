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
    @StateObject private var safety = SafetyManager()
    @State private var currentUserID: UUID?
    // Badge de no leídas en Avisos — mismo hallazgo que RootTabView.kt: no
    // había ninguna señal de "hay algo nuevo" sin entrar a mirar.
    @StateObject private var notificationsBadge = NotificationsBadgeViewModel()

    enum Tab {
        case home, match, social, avisos, perfil
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(Tab.home)

                MatchView()
                    .tabItem { Label("Match", systemImage: "square.grid.2x2.fill") }
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
            .tint(.primary)

            // Denuncia accesible desde cualquier pestaña (principio de producto
            // "seguridad primero"). No se superpone en Social: ahí la cámara ya
            // ocupa toda la pantalla y lleva su propio control de invisibilidad.
            if selectedTab != .social, let currentUserID {
                VStack {
                    SafetyToolbar(userID: currentUserID)
                    Spacer()
                }
            }
        }
        .environmentObject(safety)
        .task {
            currentUserID = try? await SupabaseManager.shared.client.auth.session.user.id
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
private struct SocialTabIcon: View {
    var body: some View {
        Label {
            Text("Social")
        } icon: {
            Text("S")
                .font(.system(size: 20, weight: .light, design: .rounded))
        }
    }
}

#Preview {
    RootTabView()
}
