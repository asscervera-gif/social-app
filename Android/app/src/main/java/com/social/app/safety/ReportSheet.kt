package com.social.app.safety

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

private val REASONS = listOf("Comportamiento inapropiado", "Perfil falso", "Acoso", "Contenido ofensivo", "Otro")

/**
 * Hoja de denuncia — equivalente Compose de ReportSheet en SafetyToolbar.swift.
 * Accesible desde cualquier pantalla (principio de producto "seguridad
 * primero"), no solo desde el perfil o el chat.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportSheet(
    reporterId: String,
    reportedId: String,
    onDismiss: () -> Unit,
    safety: SafetyManager = viewModel(),
    initialDetails: String = "",
    // Hallazgo real, comparado con Instagram/TikTok/Facebook: referencia
    // real al post/comentario denunciado (0045_reports_content_reference.sql),
    // en vez del texto libre y editable de antes ("Publicación {id}"
    // metido a mano en initialDetails).
    postId: String? = null,
    commentId: String? = null,
    // Hallazgo real, comparado con Instagram/WhatsApp/Messenger: mismo
    // hueco exacto que postId/commentId pero en un chat -- ver
    // 0048_reports_message_reference.sql.
    messageId: String? = null
) {
    var reason by remember { mutableStateOf(REASONS.first()) }
    var details by remember { mutableStateOf(initialDetails) }
    val sheetState = rememberModalBottomSheetState()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().padding(20.dp)) {
            Text("Denunciar", style = androidx.compose.material3.MaterialTheme.typography.titleLarge)

            REASONS.forEach { option ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    RadioButton(selected = reason == option, onClick = { reason = option })
                    Text(option)
                }
            }

            OutlinedTextField(
                value = details,
                onValueChange = { details = it },
                label = { Text("Detalles (opcional)") },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp)
            )
            // Hallazgo real, mismo criterio ya aplicado a caption/nombre/
            // bio: el límite de 1000 caracteres es real
            // (reports_details_length, 0024_more_text_length_limits.sql)
            // y ya se valida antes de enviar (SafetyManager.kt), pero
            // nada avisaba mientras se escribe.
            Text(
                "${details.length}/1000",
                style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                color = if (details.length > 1000) androidx.compose.material3.MaterialTheme.colorScheme.error else androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant
            )

            Button(
                onClick = {
                    safety.report(reporterId, reportedId, reason, details.ifBlank { null }, postId, commentId, messageId)
                    onDismiss()
                },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            ) {
                Text("Enviar")
            }

            // Antes SafetyManager.block() existía pero nunca se llamaba
            // desde ningún sitio de la UI en ninguna plataforma — no había
            // forma real de bloquear a nadie, solo de denunciar.
            OutlinedButton(
                onClick = {
                    safety.block(reporterId, reportedId)
                    onDismiss()
                },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp)
            ) {
                Text("Bloquear a este usuario")
            }
        }
    }
}
