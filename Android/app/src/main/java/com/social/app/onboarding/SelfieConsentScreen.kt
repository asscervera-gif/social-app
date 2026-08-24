package com.social.app.onboarding

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Face
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Consentimiento explícito de datos biométricos antes de la selfie para
 * generar el avatar — equivalente Compose de SelfieConsentView.swift.
 * Hallazgo real: este flujo (consentimiento + captura + generateAvatar)
 * nunca existió en Android en absoluto, solo en iOS, a pesar de que
 * `AvatarView.kt` (el renderer placeholder) sí tenía equivalente completo.
 */
@Composable
fun SelfieConsentScreen(onAccept: () -> Unit, onDecline: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            Icons.Filled.Face,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(bottom = 16.dp)
        )
        Text("Antes de tu selfie", style = MaterialTheme.typography.titleLarge)
        Text(
            "Para crear tu avatar 3D necesitamos procesar una foto de tu cara. " +
                "Es un dato biométrico.\n\n" +
                "• Tu foto se envía únicamente al motor de generación de avatares.\n" +
                "• No guardamos la imagen de tu cara en ningún momento: solo se " +
                "almacena el avatar 3D resultante.\n" +
                "• Puedes borrar tu avatar y volver a generarlo cuando quieras " +
                "desde tu perfil.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 16.dp)
        )
        Button(onClick = onAccept, modifier = Modifier.fillMaxWidth()) {
            Text("Acepto y continúo")
        }
        TextButton(onClick = onDecline) {
            Text("Ahora no")
        }
    }
}
