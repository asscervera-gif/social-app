package com.social.app.avatar

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp

/**
 * Hallazgo real encontrado auditando avatares: Android NUNCA renderizaba
 * ningún avatar en ningún sitio, a pesar de que `avatar_url`/`avatar_config`
 * se consultaban en varias pantallas -- el campo se traía de la base de
 * datos pero jamás se pintaba. Se corrigió primero con un círculo con
 * degradado + icono de persona (mismo criterio que iOS en ese momento).
 *
 * Esta pasada ("lo quiero exactamente igual" al boceto SOCIAL_APP.html):
 * sustituye ese degradado genérico por el busto ilustrado exacto del
 * boceto (`CartoonAvatar`, mismo path SVG) -- sigue sin ser un motor de
 * avatares 3D real, solo el ESTILO cambia. `avatar_config` ahora guarda
 * `skin`/`hair`/`top` (tres colores discretos de una paleta cerrada,
 * `AvatarLook`) en vez de un único `colorSeed` continuo.
 */
@Composable
fun AvatarView(config: Map<String, String>, size: Dp) {
    val skin = parseHexColor(config["skin"] ?: AvatarLook.SKIN_TONES.first())
    val hair = parseHexColor(config["hair"] ?: AvatarLook.HAIR_TONES.first())
    val top = parseHexColor(config["top"] ?: AvatarLook.TOP_COLORS.first())
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(Color(0xFFDFE6EE))
    ) {
        CartoonAvatar(skin = skin, hair = hair, top = top, modifier = Modifier.size(size))
    }
}

private fun parseHexColor(hex: String): Color {
    val cleaned = hex.trim().removePrefix("#")
    return try {
        val value = cleaned.toLong(16)
        val r = (value shr 16) and 0xFF
        val g = (value shr 8) and 0xFF
        val b = value and 0xFF
        Color(r / 255f, g / 255f, b / 255f)
    } catch (e: NumberFormatException) {
        Color(0xE0 / 255f, 0xAC / 255f, 0x69 / 255f)
    }
}
