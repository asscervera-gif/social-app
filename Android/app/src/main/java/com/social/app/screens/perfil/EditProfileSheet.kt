package com.social.app.screens.perfil

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.social.app.avatar.AvatarLook
import com.social.app.avatar.CartoonAvatar

/**
 * Editar nombre/bio/look de avatar — no existía en ningún sitio, ni
 * siquiera en iOS (ver PerfilViewModel.updateBasicInfo para el hallazgo
 * completo). Sin selector de foto real: la generación de avatar 3D sigue
 * sin un motor real (ver AvatarProvider), y fingir un selector de foto
 * aquí sería peor que no tenerlo — se prioriza lo que sí es real: nombre,
 * bio y el look del busto ilustrado.
 *
 * Hallazgo real de esta pasada ("lo quiero exactamente igual" al boceto
 * SOCIAL_APP.html): un único "color de avatar" (COLOR_SWATCHES suelto, sin
 * relación con el diseño real) dejó de tener sentido en cuanto el avatar
 * pasó a ser el busto ilustrado de tres colores (piel/pelo/ropa,
 * `CartoonAvatar`/`AvatarLook`) — ahora se eligen los tres por separado,
 * con vista previa en vivo, en vez de un solo swatch de color libre.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditProfileSheet(
    initialName: String,
    initialBio: String,
    initialSkin: String,
    initialHair: String,
    initialTop: String,
    onDismiss: () -> Unit,
    onSave: (String, String, String, String, String) -> Unit
) {
    var name by remember { mutableStateOf(initialName) }
    var bio by remember { mutableStateOf(initialBio) }
    var skin by remember { mutableStateOf(initialSkin) }
    var hair by remember { mutableStateOf(initialHair) }
    var top by remember { mutableStateOf(initialTop) }
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

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(top = 18.dp)
            ) {
                CartoonAvatar(
                    skin = Color(android.graphics.Color.parseColor(skin)),
                    hair = Color(android.graphics.Color.parseColor(hair)),
                    top = Color(android.graphics.Color.parseColor(top)),
                    modifier = Modifier.size(64.dp).clip(CircleShape).background(Color(0xFFDFE6EE))
                )
                Spacer(modifier = Modifier.size(12.dp))
                Text("Tu look", style = MaterialTheme.typography.titleMedium)
            }

            SwatchRow("Piel", AvatarLook.SKIN_TONES, skin) { skin = it }
            SwatchRow("Pelo", AvatarLook.HAIR_TONES, hair) { hair = it }
            SwatchRow("Ropa", AvatarLook.TOP_COLORS, top) { top = it }

            Button(
                onClick = { onSave(name, bio, skin, hair, top); onDismiss() },
                enabled = name.isNotBlank(),
                modifier = Modifier.fillMaxWidth().padding(top = 20.dp)
            ) {
                Text("Guardar")
            }
        }
    }
}

@Composable
private fun SwatchRow(label: String, options: List<String>, selected: String, onSelect: (String) -> Unit) {
    Text(label, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 16.dp))
    Row(modifier = Modifier.padding(top = 8.dp)) {
        options.forEach { hex ->
            val swatchColor = Color(android.graphics.Color.parseColor(hex))
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(swatchColor)
                    .border(
                        width = if (selected.equals(hex, ignoreCase = true)) 3.dp else 0.dp,
                        color = MaterialTheme.colorScheme.onSurface,
                        shape = CircleShape
                    )
                    .clickable { onSelect(hex) }
            )
            Spacer(modifier = Modifier.size(8.dp))
        }
    }
}
