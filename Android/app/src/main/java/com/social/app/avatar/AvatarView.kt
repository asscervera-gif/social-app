package com.social.app.avatar

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp

/**
 * Hallazgo real encontrado auditando avatares: Android NUNCA renderizaba
 * ningún avatar en ningún sitio, a pesar de que `avatar_url`/`avatar_config`
 * se consultaban en varias pantallas (HomeViewModel/MatchViewModel/
 * ProfileViewerScreen) — el campo se traía de la base de datos pero jamás
 * se pintaba. iOS sí tenía `PlaceholderAvatarProvider` desde antes de esta
 * sesión, mostrando un círculo con degradado + icono de persona. Este es
 * el equivalente Compose, misma lógica exacta (mismo color por defecto,
 * mismo overlay), para que ambas plataformas se vean igual mientras se
 * integra un motor de avatares 3D real (Avaturn/MetaPerson) — NO produce
 * avatares 3D reales, es un placeholder deliberadamente aislado, igual que
 * en iOS.
 */
@Composable
fun AvatarView(config: Map<String, String>, size: Dp) {
    val color = parseHexColor(config["colorSeed"] ?: "8B5CF6")
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(Brush.linearGradient(listOf(color, color.copy(alpha = 0.6f)))),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            Icons.Filled.Person,
            contentDescription = null,
            tint = Color.White.copy(alpha = 0.85f),
            modifier = Modifier.size(size * 0.55f)
        )
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
        Color(0x8B / 255f, 0x5C / 255f, 0xF6 / 255f)
    }
}
