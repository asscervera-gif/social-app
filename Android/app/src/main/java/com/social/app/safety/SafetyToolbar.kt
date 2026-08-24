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
 * Antes de esta corrección, el docstring de ReportSheet.kt ya afirmaba
 * "Accesible desde cualquier pantalla" pero era falso en Android: solo se
 * podía abrir desde SocialCameraScreen (tocando a un peer detectado por
 * UWB), a diferencia de iOS que sí tenía este overlay global desde el
 * principio — mismo patrón de hallazgo que otros docstrings corregidos
 * esta sesión (afirmar código que no existía).
 *
 * El modo invisible en un toque vive en SocialCameraScreen, no aquí: ahí es
 * donde tiene efecto real sobre el motor UWB (SocialProximity), así que
 * repetirlo en las otras 4 pestañas solo daría una falsa sensación de
 * control sin acción real detrás — mismo razonamiento que en iOS.
 *
 * Aviso de honestidad: desde este overlay global no hay un usuario concreto
 * en contexto (no hay perfil/chat abierto), así que `reportedId` usa el
 * propio `userId` por defecto — mismo comportamiento y misma limitación ya
 * documentada en SafetyToolbar.swift/ReportSheet.swift, pendiente de un
 * coordinador de navegación compartido entre pestañas para pasar un target
 * real desde cualquier punto.
 */
@Composable
fun SafetyToolbar(userId: String) {
    var showReportSheet by remember { mutableStateOf(false) }

    Box(modifier = Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.TopEnd) {
        FloatingActionButton(
            onClick = { showReportSheet = true },
            shape = CircleShape,
            containerColor = MaterialTheme.colorScheme.errorContainer
        ) {
            Text("⚠", style = MaterialTheme.typography.titleLarge)
        }
    }

    if (showReportSheet) {
        ReportSheet(
            reporterId = userId,
            reportedId = userId,
            onDismiss = { showReportSheet = false }
        )
    }
}
