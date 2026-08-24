package com.social.app.screens.home

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.rememberAsyncImagePainter
import kotlinx.coroutines.launch

/**
 * Compositor de publicaciones — no existía en ninguna plataforma (ver
 * NewPostViewModel para el hallazgo completo). Solo texto: sin foto/vídeo
 * porque no hay Supabase Storage real, pero `media_url` es opcional en el
 * esquema, así que esto es una publicación de verdad, no una simulación.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewPostSheet(
    viewModel: NewPostViewModel = viewModel(),
    onDismiss: () -> Unit,
    onPosted: () -> Unit
) {
    var caption by remember { mutableStateOf("") }
    var isSocialOnly by remember { mutableStateOf(false) }
    var imageUri by remember { mutableStateOf<android.net.Uri?>(null) }
    val isPosting by viewModel.isPosting.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val sheetState = rememberModalBottomSheetState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    // Hallazgo real: no había ninguna integración de Storage en el
    // proyecto — confirmado que sí hay red real en este entorno, así que
    // ya no es un bloqueo (ver StorageUploader.kt). Selector de imagen del
    // sistema, sin permiso de almacenamiento explícito necesario en
    // Android 13+ (Photo Picker), API estándar de Activity Result.
    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        imageUri = uri
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().padding(20.dp)) {
            Text("Nueva publicación", style = MaterialTheme.typography.titleLarge)

            OutlinedTextField(
                value = caption,
                onValueChange = { caption = it },
                label = { Text("¿Qué quieres contar?") },
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            )
            // Hallazgo real: el límite de 2200 caracteres es real
            // (posts_caption_length, 0023_text_length_limits.sql) y ya se
            // valida antes de publicar (NewPostViewModel.kt), pero nada
            // avisaba mientras se escribe — comparado con Instagram/
            // Twitter, que siempre muestran el contador restante.
            Text(
                "${caption.length}/2200",
                style = MaterialTheme.typography.labelSmall,
                color = if (caption.length > 2200) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )

            if (imageUri != null) {
                Image(
                    painter = rememberAsyncImagePainter(imageUri),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxWidth().height(180.dp).padding(top = 12.dp).clip(RoundedCornerShape(12.dp))
                )
            }
            OutlinedButton(
                onClick = { pickImage.launch("image/*") },
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp)
            ) {
                Text(if (imageUri == null) "Añadir foto" else "Cambiar foto")
            }

            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(checked = isSocialOnly, onCheckedChange = { isSocialOnly = it })
                Text("Solo visible para tus socials aceptados")
            }

            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp)) }

            Button(
                onClick = {
                    scope.launch {
                        if (viewModel.post(context, caption, isSocialOnly, imageUri)) {
                            onPosted()
                            onDismiss()
                        }
                    }
                },
                enabled = caption.isNotBlank() && !isPosting,
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
            ) {
                Text(if (isPosting) "Publicando…" else "Publicar")
            }
        }
    }
}
