package com.social.app.safety

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Botón flotante de denuncia, accesible desde cualquier pestaña —
 * equivalente Compose de SafetyToolbar.swift. Se añade como overlay en
 * RootTabView (principio de producto "seguridad primero").
 *
 * El modo invisible en un toque vive en SocialCameraScreen, no aquí: ahí es
 * donde tiene efecto real sobre el motor UWB (SocialProximity), así que
 * repetirlo en las otras 4 pestañas solo daría una falsa sensación de
 * control sin acción real detrás — mismo razonamiento que en iOS.
 *
 * Hallazgo real, corregido esta pasada (bug de seguridad genuino, no solo
 * cosmético): desde este overlay global nunca hay un usuario concreto en
 * contexto (no hay perfil/chat abierto), así que hasta ahora `reportedId`
 * usaba el propio `userId` por defecto — dos toques bastaban para
 * denunciarse o BLOQUEARSE a uno mismo por accidente. Ahora que el resto
 * de la app tiene entradas de denuncia/bloqueo con el target real
 * (perfil, chat, post, comentario — todas construidas en pasadas
 * recientes), este botón deja de abrir un `ReportSheet` sin sentido y en
 * su lugar explica dónde denunciar de verdad, sin ningún riesgo de
 * autodenuncia/autobloqueo silencioso.
 */
@Composable
fun SafetyToolbar(userId: String) {
    var showExplanation by remember { mutableStateOf(false) }

    Box(modifier = Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.TopEnd) {
        FloatingActionButton(
            onClick = { showExplanation = true },
            shape = CircleShape,
            containerColor = MaterialTheme.colorScheme.errorContainer
        ) {
            Text("⚠", style = MaterialTheme.typography.titleLarge)
        }
    }

    if (showExplanation) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showExplanation = false },
            title = { Text("Denunciar o bloquear") },
            text = { Text("Para denunciar o bloquear a alguien, hazlo desde su perfil, un chat, una publicación o un comentario suyo.") },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { showExplanation = false }) { Text("Entendido") }
            }
        )
    }
}
