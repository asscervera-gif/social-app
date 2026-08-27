package com.social.app.screens.reels

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
import com.social.app.util.MentionHashtagText
import com.social.app.util.MentionResolver
import io.github.jan.supabase.gotrue.auth
import kotlinx.coroutines.launch

/**
 * Hoja de comentarios de un reel -- hueco real cerrado en esta pasada, ver
 * ReelCommentsViewModel.kt. Mismo patrón visual exacto que CommentsSheet.kt
 * (posts).
 *
 * Aviso de honestidad: a diferencia de "Denunciar comentario" en posts
 * (0045_reports_content_reference.sql, referencia real al comment_id), un
 * comentario de reel se denuncia contra el AUTOR sin una columna
 * `reel_comment_id` propia en `reports` todavía -- mismo criterio que
 * tenían los comentarios de posts antes de esa migración. Hueco real
 * documentado, no fingido con una columna inventada.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReelCommentsSheet(
    reelId: String,
    onDismiss: () -> Unit,
    onCommentAdded: () -> Unit,
    onCommentRemoved: () -> Unit = {},
    onOpenProfile: (String) -> Unit = {}
) {
    val viewModel = remember(reelId) { ReelCommentsViewModel(reelId) }
    val comments by viewModel.comments.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val authorProfiles by viewModel.authorProfiles.collectAsState()
    val likedCommentIds by viewModel.likedCommentIds.collectAsState()
    val reelAuthorId by viewModel.reelAuthorId.collectAsState()
    val commentsDisabled by viewModel.commentsDisabled.collectAsState()
    var draft by remember { mutableStateOf("") }
    val sheetState = rememberModalBottomSheetState()
    val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
    var reportingAuthorId by remember { mutableStateOf<String?>(null) }
    // Responder a un comentario concreto (hilo de un nivel), comparado
    // con Instagram/Facebook/Twitter/TikTok -- ver
    // ReelCommentsViewModel.addComment(), 0104_comment_replies.sql.
    var replyingToComment by remember { mutableStateOf<ReelComment?>(null) }
    // Editar un comentario ya publicado, comparado con
    // Instagram/Facebook/Twitter/TikTok -- ver
    // ReelCommentsViewModel.editComment(), 0123_comment_edit.sql.
    var editingCommentId by remember { mutableStateOf<String?>(null) }
    var editDraft by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val mentionResolver = remember { MentionResolver() }

    LaunchedEffect(reelId) { viewModel.load() }

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
                    // TikTok -- mismo criterio real que CommentsSheet.kt
                    // (posts).
                    val isReply = comment.parentCommentId != null
                    Column(modifier = Modifier.fillMaxWidth().padding(start = if (isReply) 24.dp else 0.dp)) {
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
                            // Twitter -- ver ReelCommentsViewModel.togglePin(),
                            // 0084_pin_comments.sql.
                            if (comment.isPinned) {
                                Text("📌", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(start = 6.dp))
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            if (editingCommentId == comment.id) {
                                OutlinedTextField(
                                    value = editDraft,
                                    onValueChange = { editDraft = it },
                                    modifier = Modifier.weight(1f)
                                )
                            } else {
                                Column(modifier = Modifier.weight(1f)) {
                                    // @menciones reales (0073_profile_username.sql +
                                    // 0074_mentions.sql), comparado con Instagram/
                                    // TikTok -- mismo criterio que CommentsSheet.kt (posts).
                                    MentionHashtagText(
                                        text = comment.body,
                                        style = MaterialTheme.typography.bodyMedium,
                                        onOpenMention = { username ->
                                            scope.launch { mentionResolver.resolveProfileId(username)?.let(onOpenProfile) }
                                        }
                                    )
                                    if (comment.editedAt != null) {
                                        Text(
                                            "(editado)",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                }
                            }
                            // Comparado con Instagram/Twitter/Facebook: dar
                            // like a un comentario concreto (0054_comment_likes.sql).
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
                            // Twitter/TikTok -- solo sobre un comentario
                            // de primer nivel (límite real de un solo
                            // nivel, 0104_comment_replies.sql).
                            if (!isReply) {
                                TextButton(onClick = { replyingToComment = comment }) {
                                    Text("Responder")
                                }
                            }
                            // Fijar un comentario (propio o ajeno), comparado
                            // con Instagram/Twitter -- solo visible para el
                            // autor real del reel, mismo criterio que
                            // `reel_comments_update_pin` en RLS.
                            if (reelAuthorId != null && reelAuthorId == myId) {
                                TextButton(onClick = { viewModel.togglePin(comment) }) {
                                    Text(if (comment.isPinned) "Desfijar" else "Fijar")
                                }
                            }
                            if (comment.authorId == myId) {
                                if (editingCommentId == comment.id) {
                                    TextButton(onClick = {
                                        viewModel.editComment(comment, editDraft)
                                        editingCommentId = null
                                    }) { Text("Guardar") }
                                    TextButton(onClick = { editingCommentId = null }) { Text("Cancelar") }
                                } else {
                                    TextButton(onClick = {
                                        editingCommentId = comment.id
                                        editDraft = comment.body
                                    }) { Text("Editar") }
                                }
                            }
                            if (comment.authorId == myId) {
                                TextButton(onClick = { viewModel.deleteComment(comment) { onCommentRemoved() } }) {
                                    Text("Borrar")
                                }
                            } else {
                                TextButton(onClick = { reportingAuthorId = comment.authorId }) {
                                    Text("⋯")
                                }
                            }
                        }
                    }
                }
            }

            // Desactivar los comentarios de un reel, comparado con
            // Instagram/TikTok -- el autor real cerró la puerta a
            // comentarios nuevos (0086_disable_comments.sql); los que ya
            // existían se siguen viendo con normalidad arriba.
            if (commentsDisabled) {
                Text(
                    "El autor ha desactivado los comentarios en este reel.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp)
                )
            } else {
                // Responder a un comentario concreto (hilo de un nivel),
                // comparado con Instagram/Facebook/Twitter/TikTok --
                // mismo criterio real que CommentsSheet.kt (posts).
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

    reportingAuthorId?.let { authorId ->
        if (myId != null) {
            com.social.app.safety.ReportSheet(
                reporterId = myId,
                reportedId = authorId,
                onDismiss = { reportingAuthorId = null }
            )
        }
    }
}
