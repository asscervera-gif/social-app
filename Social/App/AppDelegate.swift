//
//  AppDelegate.swift
//  Social
//
//  UIApplicationDelegate mínimo, solo para los callbacks de push (APNs) que
//  la App de SwiftUI no expone directamente -- conectado vía
//  @UIApplicationDelegateAdaptor en SocialApp.swift.
//

import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Sin esto, un aviso local con la app en primer plano no se
        // presenta nunca y tocarlo no lleva a ningún sitio -- ver
        // NotificationDelegate.swift.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushTokenManager.register(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Aviso de honestidad: sin cuenta Apple Developer de pago ni
        // dispositivo físico en este entorno (decisión explícita del
        // usuario -- CI de "solo compilador + Simulador"), este callback
        // nunca se ha podido observar disparándose de verdad.
    }
}
