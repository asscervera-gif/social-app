package com.social.app.proximity

import java.util.UUID

/**
 * Equivalente Kotlin de PeerToken.swift/PeerProximity — mismo modelo que la
 * versión iOS para que ambas plataformas se comporten igual de cara al resto
 * de la app (backend, UI, reglas de producto).
 */
data class SocialPeerId(val id: UUID)

data class PeerProximity(
    val peerId: SocialPeerId,
    val distanceMeters: Float? = null,
    val horizontalAngleRad: Float? = null,
    val isInFrame: Boolean = false,
    val isActive: Boolean = true,
    /** profile_id real de Supabase del peer, intercambiado durante el
     * handshake Nearby (ver aviso de honestidad/seguridad en
     * SocialProximity.kt) — null hasta que llega, o si el peer no está
     * autenticado. Es lo único que permite enviar un social de verdad al
     * tocar un marcador, ya que peerId es un UUID efímero de sesión. */
    val profileId: String? = null
)
