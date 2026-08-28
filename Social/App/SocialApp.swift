//
//  SocialApp.swift
//  Social
//
//  Punto de entrada de la app. RootTabView gestiona las cinco pestañas, con
//  "Social" (la cámara) como pestaña por defecto — la app nunca abre en un
//  feed, según el principio de producto de SOCIAL.
//
//  Hallazgo real más grave de la sesión: antes se mostraba RootTabView
//  siempre, sin comprobar sesión — ver AppRootView.swift/AuthView.swift.
//

import SwiftUI

@main
struct SocialApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Tiempo en pantalla real ("Bienestar digital"), comparado con
    // Instagram/TikTok/Facebook/Snapchat -- ver ScreenTimeManager.swift,
    // 0149_screen_time.sql. Equivalente de MainActivity.kt.onStart()/
    // onStop().
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                ScreenTimeManager.startSession()
            } else if newPhase == .background {
                ScreenTimeManager.endSession()
            }
        }
    }
}
