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

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
