package com.social.app.screens.home

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import io.github.jan.supabase.gotrue.auth
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.social.app.util.MentionHashtagText
import com.social.app.util.MentionResolver
import com.social.app.util.relativeTime
import kotlinx.coroutines.launch

/**
 * Publicación individual real ("permalink"), comparado con Instagram/
 * Twitter/Facebook -- ver PostDetailViewModel.kt para el hallazgo
 * completo: ni el feed tenía esta pantalla, ni un aviso de "like"/
 * "comentario" llevaba a ningún sitio (tap muerto, ver AvisosScreen.kt).
 */
@Composable
fun PostDetailScreen(postId: String, onOpenProfile: (String) -> Unit) {
    val viewModel = remember(postId) { PostDetailViewModel(postId) }
    val post by viewModel.post.collectAsState()
    val author by viewModel.author.collectAsState()
    val extraMedia by viewModel.extraMedia.collectAsState()
    val isLiked by viewModel.isLiked.collectAsState()
    val isSaved by viewModel.isSaved.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    // Encuesta real en una publicación normal, comparado con Twitter/X/
    // Facebook -- cierra el hueco deliberado documentado desde
    // 0113_post_polls.sql: el feed ya la soportaba, esta pantalla
    // ("permalink") todavía no.
    val postPoll by viewModel.postPoll.collectAsState()
    val myPollVote by viewModel.myPollVote.collectAsState()
    var showComments by remember { mutableStateOf(false) }
    var fullScreenUrl by remember { mutableStateOf<String?>(null) }
    // Marcar contenido como sensible, comparado con Instagram/Twitter/
    // TikTok -- estado local de la propia pantalla, ver
    // 0096_sensitive_content.sql.
    var sensitiveRevealed by remember(postId) { mutableStateOf(false) }
    val myId = com.social.app.backend.SupabaseManager.client.auth.currentUserOrNull()?.id
    val scope = rememberCoroutineScope()
    val mentionResolver = remember { MentionResolver() }

    LaunchedEffect(postId) { viewModel.load() }

    Column(modifier = Modifier.fillMaxSize().padding(12.dp)) {
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        post?.let { post ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().clickable { onOpenProfile(post.authorId) }.padding(bottom = 8.dp)
            ) {
                com.social.app.avatar.AvatarView(config = author?.avatarConfig ?: emptyMap(), size = 36.dp)
                Text(
                    author?.displayName ?: "…",
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.padding(start = 10.dp)
                )
            }
            // Etiqueta de ubicación real (texto libre, no geocodificado),
            // comparado con Instagram/Facebook/Twitter/Snapchat -- ver
            // 0095_post_location_tag.sql.
            post.locationName?.let { location ->
                Text(
                    "📍 $location",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp)
                )
            }
            post.mediaUrl?.let { firstUrl ->
                // Marcar contenido como sensible, comparado con
                // Instagram/Twitter/TikTok -- mismo criterio que
                // HomeScreen.kt.PostCard, ver 0096_sensitive_content.sql.
                val needsSensitiveWarning = post.isSensitive && post.authorId != myId && !sensitiveRevealed
                if (needsSensitiveWarning) {
                    Column(
                        modifier = Modifier.fillMaxWidth().height(320.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(bottom = 8.dp)
                            .clickable { sensitiveRevealed = true },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Text("⚠️ Puede contener contenido sensible", style = MaterialTheme.typography.bodyMedium)
                        Text("Toca para ver", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    // Carrusel de varias fotos (post_media), mismo patrón
                    // exacto que HomeScreen.kt.PostCard.
                    val allUrls = remember(firstUrl, extraMedia) { listOf(firstUrl) + extraMedia }
                    if (allUrls.size == 1) {
                        Image(
                            painter = coil.compose.rememberAsyncImagePainter(firstUrl),
                            contentDescription = null,
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                            modifier = Modifier.fillMaxWidth().height(320.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .padding(bottom = 8.dp)
                                .clickable { fullScreenUrl = firstUrl }
                        )
                    } else {
                        val pagerState = rememberPagerState(pageCount = { allUrls.size })
                        Box(modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
                            HorizontalPager(
                                state = pagerState,
                                modifier = Modifier.fillMaxWidth().height(320.dp).clip(RoundedCornerShape(8.dp))
                            ) { page ->
                                val url = allUrls[page]
                                Image(
                                    painter = coil.compose.rememberAsyncImagePainter(url),
                                    contentDescription = null,
                                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize().clickable { fullScreenUrl = url }
                                )
                            }
                            Text(
                                "${pagerState.currentPage + 1}/${allUrls.size}",
                                style = MaterialTheme.typography.labelSmall,
                                color = Color.White,
                                modifier = Modifier
                                    .align(Alignment.TopEnd)
                                    .padding(8.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(Color.Black.copy(alpha = 0.5f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                    }
                }
            }
            // @menciones reales (0073_profile_username.sql +
            // 0074_mentions.sql), comparado con Instagram/Twitter/TikTok --
            // esta pantalla ni siquiera tenía etiquetas tocables (a
            // diferencia del feed, HomeScreen.kt.PostCard), solo texto
            // plano; se corrige de paso al construir el mismo componente
            // compartido aquí.
            post.caption?.let { caption ->
                MentionHashtagText(
                    text = caption,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(bottom = 4.dp),
                    onOpenMention = { username ->
                        scope.launch { mentionResolver.resolveProfileId(username)?.let(onOpenProfile) }
                    }
                )
            }
            // Mismo patrón visual exacto que HomeScreen.kt.PostCard:
            // botones antes de votar, barras de porcentaje después.
            postPoll?.let { p ->
                Column(modifier = Modifier.padding(top = 8.dp, bottom = 4.dp).fillMaxWidth()) {
                    Text(p.question, style = MaterialTheme.typography.titleSmall)
                    val totalVotes = p.voteCounts.sum()
                    p.options.forEachIndexed { optionIndex, optionText ->
                        if (myPollVote != null) {
                            val votesForOption = p.voteCounts.getOrElse(optionIndex) { 0 }
                            val percent = if (totalVotes == 0) 0 else (votesForOption * 100) / totalVotes
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = 6.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth(percent / 100f)
                                        .background(
                                            if (optionIndex == myPollVote) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                                            RoundedCornerShape(8.dp)
                                        )
                                )
                                Text("$optionText · $percent%", modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp))
                            }
                        } else {
                            androidx.compose.material3.OutlinedButton(
                                onClick = { viewModel.voteOnPoll(optionIndex) },
                                modifier = Modifier.fillMaxWidth().padding(top = 6.dp)
                            ) { Text(optionText) }
                        }
                    }
                }
            }
            Text(
                relativeTime(post.createdAt),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.padding(top = 8.dp)) {
                // Ocultar el número de "me gusta" real, comparado con
                // Instagram/Facebook -- el propio autor sigue viendo su
                // cifra real siempre, solo desaparece para los demás. Ver
                // 0094_hide_like_count.sql.
                val showLikeCount = !post.hideLikeCount || post.authorId == myId
                Text(
                    if (showLikeCount) "${if (isLiked) "❤" else "🤍"} ${post.likeCount}" else if (isLiked) "❤" else "🤍",
                    modifier = Modifier.clickable { viewModel.toggleLike() }
                )
                Text("💬 ${post.commentCount}", modifier = Modifier.clickable { showComments = true })
                Text(if (isSaved) "🔖" else "📑", modifier = Modifier.clickable { viewModel.toggleSave() })
            }
        }
    }

    if (showComments) {
        CommentsSheet(
            postId = postId,
            onDismiss = { showComments = false },
            onCommentAdded = { viewModel.commentAdded() },
            onCommentRemoved = { viewModel.commentRemoved() },
            onOpenProfile = onOpenProfile
        )
    }
    fullScreenUrl?.let { url ->
        com.social.app.util.FullScreenImageViewer(url = url, onDismiss = { fullScreenUrl = null })
    }
}
