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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Comment
import com.social.app.util.MentionHashtagText
import com.social.app.util.MentionResolver
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.launch

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
    val likedCommentIds by viewModel.likedCommentIds.collectAsState()
    val postAuthorId by viewModel.postAuthorId.collectAsState()
    val commentsDisabled by viewModel.commentsDisabled.collectAsState()
    var draft by remember { mutableStateOf("") }
    val sheetState = rememberModalBottomSheetState()
    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    // Hallazgo real: mismo patrón que "Denunciar publicación" — solo
    // existía denuncia global de usuario, ahora también por comentario
    // concreto (mismo criterio: sin columna nueva, se denuncia al autor
    // con el id del comentario en los detalles).
    var reportingCommentId by remember { mutableStateOf<String?>(null) }
    // Responder a un comentario concreto (hilo de un nivel), comparado
    // con Instagram/Facebook/Twitter/TikTok -- ver
    // CommentsViewModel.addComment(), 0104_comment_replies.sql.
    var replyingToComment by remember { mutableStateOf<Comment?>(null) }
    val scope = rememberCoroutineScope()
    val mentionResolver = remember { MentionResolver() }

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
                    // Responder a un comentario concreto (hilo de un
                    // nivel), comparado con Instagram/Facebook/Twitter/
                    // TikTok -- una respuesta real va sangrada bajo el
                    // comentario de primer nivel que responde (ya en el
                    // orden correcto real, ver
                    // CommentsViewModel.threadOrder()).
                    val isReply = comment.parentCommentId != null
                    Column(modifier = Modifier.fillMaxWidth().padding(start = if (isReply) 24.dp else 0.dp)) {
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
                            // Fijar un comentario, comparado con Instagram/
                            // Twitter -- ver CommentsViewModel.togglePin(),
                            // 0084_pin_comments.sql. El propio icono ya
                            // comunica el estado, visible para cualquiera
                            // (mismo criterio que WhatsApp con "Fijado").
                            if (comment.isPinned) {
                                Text("📌", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(start = 6.dp))
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            // @menciones reales (0073_profile_username.sql +
                            // 0074_mentions.sql), comparado con Instagram/
                            // Twitter/TikTok -- tocar un @usuario dentro de
                            // un comentario real abre ese perfil.
                            MentionHashtagText(
                                text = comment.body,
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.weight(1f),
                                onOpenMention = { username ->
                                    scope.launch { mentionResolver.resolveProfileId(username)?.let(onOpenProfile) }
                                }
                            )
                            // Comparado con Instagram/Twitter/Facebook: dar
                            // like a un comentario concreto, no solo a la
                            // publicación entera (0054_comment_likes.sql).
                            val liked = likedCommentIds.contains(comment.id)
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.clickable { viewModel.toggleCommentLike(comment) }
                            ) {
                                Text(if (liked) "❤" else "🤍", style = MaterialTheme.typography.labelMedium)
                                if (comment.likeCount > 0) {
                                    Text(
                                        "${comment.likeCount}",
                                        style = MaterialTheme.typography.labelSmall,
                                        modifier = Modifier.padding(start = 2.dp)
                                    )
                                }
                            }
                            // Responder a un comentario concreto (hilo de
                            // un nivel), comparado con Instagram/Facebook/
                            // Twitter/TikTok -- solo sobre un comentario de
                            // primer nivel (límite real de un solo nivel,
                            // ver 0104_comment_replies.sql: el propio
                            // trigger lo exige, aquí se refleja no
                            // ofreciendo el botón sobre una respuesta ya
                            // existente).
                            if (!isReply) {
                                TextButton(onClick = { replyingToComment = comment }) {
                                    Text("Responder")
                                }
                            }
                            // Fijar un comentario (propio o ajeno), comparado
                            // con Instagram/Twitter -- solo visible para el
                            // autor real de la publicación, mismo criterio
                            // que `comments_update_pin` en RLS.
                            if (postAuthorId != null && postAuthorId == myId) {
                                TextButton(onClick = { viewModel.togglePin(comment) }) {
                                    Text(if (comment.isPinned) "Desfijar" else "Fijar")
                                }
                            }
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

            // Desactivar los comentarios de una publicación, comparado con
            // Instagram/TikTok -- el autor real cerró la puerta a
            // comentarios nuevos (0086_disable_comments.sql); los que ya
            // existían se siguen viendo con normalidad arriba.
            if (commentsDisabled) {
                Text(
                    "El autor ha desactivado los comentarios en esta publicación.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp)
                )
            } else {
                // Responder a un comentario concreto (hilo de un nivel),
                // comparado con Instagram/Facebook/Twitter/TikTok -- vista
                // previa real de a qué comentario se está respondiendo,
                // con una forma real de cancelarlo antes de publicar.
                replyingToComment?.let { replyTarget ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            "Respondiendo a ${authorProfiles[replyTarget.authorId]?.displayName ?: "…"}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.primary
                        )
                        TextButton(onClick = { replyingToComment = null }) { Text("✕") }
                    }
                }
                Row(modifier = Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        modifier = Modifier.weight(1f),
                        placeholder = { Text(if (replyingToComment != null) "Escribe una respuesta…" else "Escribe un comentario…") }
                    )
                    Button(
                        onClick = {
                            viewModel.addComment(draft, replyingToComment?.id) { onCommentAdded() }
                            draft = ""
                            replyingToComment = null
                        },
                        modifier = Modifier.padding(start = 8.dp)
                    ) {
                        Text("➤")
                    }
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
