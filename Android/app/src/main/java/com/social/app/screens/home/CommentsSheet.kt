package com.social.app.screens.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth

/**
 * Hoja de comentarios de un post — equivalente de la funcionalidad que
 * faltaba (ver 0008_comments.sql). Lista + campo para publicar uno nuevo,
 * mismo patrón visual que ReportSheet.kt/SendSocialSheet.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CommentsSheet(
    postId: String,
    onDismiss: () -> Unit,
    onCommentAdded: () -> Unit,
    onCommentRemoved: () -> Unit = {},
    onOpenProfile: (String) -> Unit = {}
) {
    val viewModel = remember(postId) { CommentsViewModel(postId) }
    val comments by viewModel.comments.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val authorProfiles by viewModel.authorProfiles.collectAsState()
    var draft by remember { mutableStateOf("") }
    val sheetState = rememberModalBottomSheetState()
    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    // Hallazgo real: mismo patrón que "Denunciar publicación" — solo
    // existía denuncia global de usuario, ahora también por comentario
    // concreto (mismo criterio: sin columna nueva, se denuncia al autor
    // con el id del comentario en los detalles).
    var reportingCommentId by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(postId) { viewModel.load() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Comentarios", style = MaterialTheme.typography.titleMedium)

            if (isLoading && comments.isEmpty()) {
                CircularProgressIndicator(modifier = Modifier.padding(top = 12.dp))
            }
            errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }

            LazyColumn(
                modifier = Modifier.fillMaxWidth().height(280.dp).padding(top = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(comments, key = { it.id }) { comment ->
                    val author = authorProfiles[comment.authorId]
                    Column(modifier = Modifier.fillMaxWidth()) {
                        // Hallazgo real, mismo hueco raíz que el feed
                        // (HomeViewModel.authorProfiles, pasada anterior):
                        // nunca se mostraba QUIÉN escribió cada comentario,
                        // comparado con cualquier app grande.
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable { onOpenProfile(comment.authorId) }
                        ) {
                            com.social.app.avatar.AvatarView(config = author?.avatarConfig ?: emptyMap(), size = 20.dp)
                            Text(
                                author?.displayName ?: "…",
                                style = MaterialTheme.typography.labelMedium,
                                modifier = Modifier.padding(start = 6.dp)
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(comment.body, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                            // Hallazgo real: no había forma de borrar el propio
                            // comentario, comparado con cualquier app grande —
                            // `comments_delete_own` ya lo permitía en RLS.
                            if (comment.authorId == myId) {
                                TextButton(onClick = { viewModel.deleteComment(comment) { onCommentRemoved() } }) {
                                    Text("Borrar")
                                }
                            } else {
                                TextButton(onClick = { reportingCommentId = comment.id }) {
                                    Text("⋯")
                                }
                            }
                        }
                    }
                }
            }

            Row(modifier = Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Escribe un comentario…") }
                )
                Button(
                    onClick = {
                        viewModel.addComment(draft) { onCommentAdded() }
                        draft = ""
                    },
                    modifier = Modifier.padding(start = 8.dp)
                ) {
                    Text("➤")
                }
            }
        }
    }

    reportingCommentId?.let { commentId ->
        val comment = comments.firstOrNull { it.id == commentId }
        if (comment != null && myId != null) {
            com.social.app.safety.ReportSheet(
                reporterId = myId,
                reportedId = comment.authorId,
                // Hallazgo real, comparado con Instagram/TikTok/Facebook:
                // antes esto era un texto libre editable; ahora una
                // referencia real (0045_reports_content_reference.sql).
                commentId = commentId,
                onDismiss = { reportingCommentId = null }
            )
        }
    }
}
