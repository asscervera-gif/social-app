package com.social.app.screens.search

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/**
 * Buscador de personas — no existía en ninguna plataforma, comparado con
 * Instagram/TikTok/Snapchat (ver SearchViewModel.kt para el hallazgo
 * completo). Desde esta pasada, un texto que empieza por "#" busca
 * publicaciones en vez de personas (mismo criterio que el Explorar de
 * Instagram/la búsqueda de TikTok).
 */
@Composable
fun SearchScreen(viewModel: SearchViewModel = viewModel(), onOpenProfile: (String) -> Unit, initialHashtag: String? = null) {
    LaunchedEffect(initialHashtag) {
        // Llega desde CaptionText (HomeScreen.kt) al tocar una etiqueta en
        // una publicación real — sin esto, tocar la etiqueta abriría el
        // buscador vacío en vez de con los resultados de esa etiqueta.
        if (!initialHashtag.isNullOrBlank()) {
            viewModel.onQueryChange("#$initialHashtag")
        }
    }
    val query by viewModel.query.collectAsState()
    val results by viewModel.results.collectAsState()
    val postResults by viewModel.postResults.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val isHashtagMode = query.trimStart().startsWith("#")

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Buscar", style = MaterialTheme.typography.headlineSmall)
        OutlinedTextField(
            value = query,
            onValueChange = { viewModel.onQueryChange(it) },
            label = { Text("Nombre o #etiqueta") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
        )
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        val noResults = if (isHashtagMode) postResults.isEmpty() else results.isEmpty()
        if (query.isNotBlank() && noResults && errorMessage == null) {
            Text(
                "Sin resultados.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 16.dp)
            )
        }
        if (isHashtagMode) {
            LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                items(postResults, key = { it.id }) { post ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onOpenProfile(post.authorId) }
                            .padding(vertical = 10.dp)
                    ) {
                        post.caption?.let { Text(it) }
                        Text(
                            "❤ ${post.likeCount}  💬 ${post.commentCount}",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.labelMedium
                        )
                    }
                }
            }
        } else {
            LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                items(results, key = { it.id }) { profile ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onOpenProfile(profile.id) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        com.social.app.avatar.AvatarView(config = profile.avatarConfig ?: emptyMap(), size = 44.dp)
                        Text(profile.displayName, modifier = Modifier.padding(start = 12.dp))
                        // Hallazgo real: `is_verified` se consultaba pero nunca
                        // se renderizaba como badge en ningún sitio de la app.
                        if (profile.isVerified) {
                            Text(" ✔️", color = MaterialTheme.colorScheme.primary)
                        }
                    }
                }
            }
        }
    }
}
