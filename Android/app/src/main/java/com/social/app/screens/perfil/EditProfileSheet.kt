package com.social.app.screens.perfil

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

private val COLOR_SWATCHES = listOf("8B5CF6", "EF4444", "F59E0B", "10B981", "3B82F6", "EC4899")

/**
 * Editar nombre/bio/color de avatar — no existía en ningún sitio, ni
 * siquiera en iOS (ver PerfilViewModel.updateBasicInfo para el hallazgo
 * completo). Sin selector de foto real: la generación de avatar 3D sigue
 * sin onboarding construido, y fingir un selector de foto aquí sin que
 * `avatar_url` se use en ningún renderizado real sería peor que no
 * tenerlo — se prioriza lo que sí es real: nombre, bio y color.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditProfileSheet(
    initialName: String,
    initialBio: String,
    initialColor: String,
    onDismiss: () -> Unit,
    onSave: (String, String, String) -> Unit
) {
    var name by remember { mutableStateOf(initialName) }
    var bio by remember { mutableStateOf(initialBio) }
    var color by remember { mutableStateOf(initialColor) }
    val sheetState = rememberModalBottomSheetState()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().padding(20.dp)) {
            Text("Editar perfil", style = MaterialTheme.typography.titleLarge)

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Nombre") },
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
            )
            // Hallazgo real, mismo criterio ya aplicado al caption de
            // posts: los límites de 50/300 caracteres son reales
            // (profiles_display_name_length/profiles_bio_length,
            // 0023_text_length_limits.sql) y ya se validan antes de
            // guardar (PerfilViewModel.kt), pero nada avisaba mientras se
            // escribe — comparado con Instagram/Twitter, que siempre
            // muestran el contador restante en nombre/bio.
            Text(
                "${name.length}/50",
                style = MaterialTheme.typography.labelSmall,
                color = if (name.length > 50) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
            )
            OutlinedTextField(
                value = bio,
                onValueChange = { bio = it },
                label = { Text("Bio") },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            )
            Text(
                "${bio.length}/300",
                style = MaterialTheme.typography.labelSmall,
                color = if (bio.length > 300) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
            )

            Text("Color de avatar", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 16.dp))
            Row(modifier = Modifier.padding(top = 8.dp)) {
                COLOR_SWATCHES.forEach { hex ->
                    val swatchColor = Color(android.graphics.Color.parseColor("#$hex"))
                    Row {
                        androidx.compose.foundation.layout.Box(
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape)
                                .background(swatchColor)
                                .border(
                                    width = if (color == hex) 3.dp else 0.dp,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    shape = CircleShape
                                )
                                .clickable { color = hex }
                        )
                        androidx.compose.foundation.layout.Spacer(modifier = Modifier.size(8.dp))
                    }
                }
            }

            Button(
                onClick = { onSave(name, bio, color); onDismiss() },
                enabled = name.isNotBlank(),
                modifier = Modifier.fillMaxWidth().padding(top = 20.dp)
            ) {
                Text("Guardar")
            }
        }
    }
}
