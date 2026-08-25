package com.social.app.backend

import com.google.firebase.messaging.FirebaseMessagingService

/**
 * Equivalente Android de AppDelegate.swift (el callback de registro de
 * token APNs) -- declarado en AndroidManifest.xml. FCM llama a onNewToken()
 * la primera vez que genera un token y cada vez que lo renueva; no cubre el
 * caso de un usuario que ya tenía un token válido al reabrir la app, por
 * eso AppRoot.kt también llama a PushTokenManager.registerCurrentToken()
 * directamente al detectar sesión real.
 */
class SocialFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        PushTokenManager.register(token)
    }
}
