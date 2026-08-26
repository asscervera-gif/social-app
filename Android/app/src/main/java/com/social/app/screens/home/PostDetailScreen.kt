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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.social.app.util.relativeTime

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
    var showComments by remember { mutableStateOf(false) }
    var fullScreenUrl by remember { mutableStateOf<String?>(null) }

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
            post.mediaUrl?.let { firstUrl ->
                // Carrusel de varias fotos (post_media), mismo patrón exacto
                // que HomeScreen.kt.PostCard.
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
            post.caption?.let { Text(it, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(bottom = 4.dp)) }
            Text(
                relativeTime(post.createdAt),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.padding(top = 8.dp)) {
                Text(
                    "${if (isLiked) "❤" else "🤍"} ${post.likeCount}",
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
