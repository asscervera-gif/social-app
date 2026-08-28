package com.social.app.screens.match

import android.location.Location
import android.location.LocationManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.model.Profile

private enum class MatchFilter(val label: String) {
    CERCA("Cerca"), COMPATIBLES("Compatibles"), NUEVOS("Nuevos"), GUSTOS("Tus gustos")
}

/** Paleta de degradados del boceto (match_boceto.html .card) — se asigna por
 * posición en la lista, no por identidad de usuario, igual que el mockup. */
private val cardGradients = listOf(
    listOf(Color(0xFFFFD8A8), Color(0xFFFFA8A8)),
    listOf(Color(0xFFA5D8FF), Color(0xFFD0BFFF)),
    listOf(Color(0xFFB2F2BB), Color(0xFF96F2D7)),
    listOf(Color(0xFFFFC9DE), Color(0xFFEEBEFA))
)

/**
 * Cuadrícula de perfiles — redisenio fiel a match_boceto.html (título con
 * lupa, buscador, chips de filtro, tarjetas 2 columnas con degradado y
 * nombre/compatibilidad superpuestos). Compatibilidad visible si el dueño
 * la tiene pública; si no, "?%" y botón para solicitarla — misma regla que
 * MatchView.swift y que el prototipo web (matchCompatWidget).
 *
 * Los 4 chips del boceto eran solo decorativos en la maqueta — aquí filtran/
 * ordenan de verdad sobre datos reales: "Compatibles" por % descendente,
 * "Tus gustos" por solapamiento real de intereses, "Nuevos" por
 * profiles.created_at, y "Cerca" por distancia real a partir de
 * last_lat/last_lng (ver el hallazgo gemelo en
 * PrivacySettingsViewModel.kt.publishCurrentLocation — antes esa columna
 * nunca se escribía, así que "Cerca" no podía haber funcionado nunca).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MatchScreen(viewModel: MatchViewModel = viewModel(), onOpenProfile: (String) -> Unit = {}) {
    val entries by viewModel.entries.collectAsState()
    val myInterests by viewModel.myInterests.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    LaunchedEffect(Unit) { viewModel.load() }

    val context = LocalContext.current
    var myLocation by remember { mutableStateOf<Location?>(null) }
    LaunchedEffect(Unit) {
        try {
            val locationManager = context.getSystemService(LocationManager::class.java)
            myLocation = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
                .mapNotNull { runCatching { locationManager?.getLastKnownLocation(it) }.getOrNull() }
                .firstOrNull()
        } catch (e: SecurityException) {
            // Sin permiso de ubicación concedido todavía: "Cerca" simplemente
            // no reordena nada, el resto de la pantalla sigue funcionando.
        }
    }

    var searchQuery by remember { mutableStateOf("") }
    var selectedFilter by remember { mutableStateOf(MatchFilter.CERCA) }

    val visibleEntries = remember(entries, searchQuery, selectedFilter, myLocation, myInterests) {
        var list = entries
        if (searchQuery.isNotBlank()) {
            val q = searchQuery.trim().lowercase()
            list = list.filter { entry ->
                entry.profile.displayName.lowercase().contains(q) ||
                    entry.profile.interests.any { it.lowercase().contains(q) }
            }
        }
        when (selectedFilter) {
            MatchFilter.CERCA -> {
                val here = myLocation
                if (here == null) list else list.sortedBy { distanceKmOrNull(here, it.profile) ?: Float.MAX_VALUE }
            }
            MatchFilter.COMPATIBLES -> list.sortedByDescending { it.compatibility ?: -1 }
            MatchFilter.NUEVOS -> list.sortedByDescending { it.profile.createdAt ?: "" }
            MatchFilter.GUSTOS -> list.filter { it.profile.interests.any { i -> i in myInterests } }
        }
    }

    val pullState = rememberPullToRefreshState()
    if (pullState.isRefreshing) {
        LaunchedEffect(Unit) {
            viewModel.load()
            pullState.endRefresh()
        }
    }

    Box(modifier = Modifier.fillMaxSize().nestedScroll(pullState.nestedScrollConnection)) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                "🔍 Match",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.fillMaxWidth().padding(16.dp, 16.dp, 16.dp, 10.dp)
            )
            TextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("🔍 Buscar por intereses, ciudad, gustos...", fontSize = 13.sp, color = Color(0xFF888888)) },
                singleLine = true,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color(0xFFF1F3F5),
                    unfocusedContainerColor = Color(0xFFF1F3F5),
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent
                ),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 10.dp)
            )
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                MatchFilter.values().forEach { filter ->
                    val active = filter == selectedFilter
                    Text(
                        filter.label,
                        fontSize = 12.sp,
                        color = if (active) Color.White else Color(0xFF555555),
                        modifier = Modifier
                            .clip(RoundedCornerShape(14.dp))
                            .background(if (active) Color(0xFF111111) else Color(0xFFF1F3F5))
                            .clickable { selectedFilter = filter }
                            .padding(horizontal = 14.dp, vertical = 8.dp)
                    )
                }
            }
            Box(modifier = Modifier.padding(top = 14.dp)) {
                errorMessage?.let { message ->
                    Text(message, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp))
                }
            }
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth().padding(16.dp, 0.dp, 16.dp, 16.dp)
            ) {
                itemsIndexed(visibleEntries) { index, entry ->
                    MatchCard(
                        entry = entry,
                        gradient = cardGradients[index % cardGradients.size],
                        onOpen = { onOpenProfile(entry.profile.id) },
                        onRequest = { viewModel.requestCompatibility(entry) },
                        onRequestHighlighted = { viewModel.requestCompatibility(entry, highlighted = true) }
                    )
                }
            }
        }
        PullToRefreshContainer(state = pullState, modifier = Modifier.align(Alignment.TopCenter))
    }
}

@Composable
private fun MatchCard(
    entry: MatchViewModel.Entry,
    gradient: List<Color>,
    onOpen: () -> Unit,
    onRequest: () -> Unit,
    // "Interés destacado" real, comparado con Tinder/Bumble (Super Like)
    // -- ver MatchViewModel.requestCompatibility(highlighted=true),
    // 0136_compat_request_highlight.sql.
    onRequestHighlighted: () -> Unit = {}
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(0.8f)
            .clip(RoundedCornerShape(14.dp))
            .background(Brush.linearGradient(gradient))
            .clickable(onClick = onOpen)
    ) {
        Box(
            modifier = Modifier
                .padding(10.dp)
                .size(32.dp)
                .clip(CircleShape)
                .background(Color.White)
                .align(Alignment.TopStart)
        ) {
            com.social.app.avatar.AvatarView(config = entry.profile.avatarConfig ?: emptyMap(), size = 32.dp)
        }
        // Hallazgo real: la maqueta pinta "?%" como texto fijo, pero la app
        // real ya distingue "compatibilidad pública" de "compatibilidad
        // solicitada" (ver MatchViewModel.requestCompatibility) — el badge
        // aquí conserva los 3 estados reales en vez de perder el de
        // "Solicitado" solo por igualar el mockup al pixel.
        val badge = when {
            entry.compatibility != null -> BadgeState("${entry.compatibility}%", Color(0xFF20BF6B), Color.White, clickable = false)
            entry.requestSent -> BadgeState("Solicitado", Color(0xB3FFFFFF), Color(0xFF888888), clickable = false)
            else -> BadgeState("?% · Pedir", Color(0xB3FFFFFF), Color(0xFF888888), clickable = true)
        }
        Text(
            badge.text,
            fontSize = 10.5.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
            color = badge.fg,
            maxLines = 1,
            overflow = TextOverflow.Clip,
            modifier = Modifier
                .padding(10.dp)
                .align(Alignment.TopEnd)
                .clip(RoundedCornerShape(9.dp))
                .background(badge.bg)
                .let { if (badge.clickable) it.clickable(onClick = onRequest) else it }
                .padding(horizontal = 8.dp, vertical = 4.dp)
        )
        // "Interés destacado" real, comparado con Tinder/Bumble (Super
        // Like) -- solo tiene sentido mientras la compatibilidad real
        // todavía no se sabe ni ya se pidió (mismo criterio que el badge
        // "?% · Pedir" de arriba).
        if (badge.clickable) {
            Text(
                "⭐",
                fontSize = 14.sp,
                modifier = Modifier
                    .padding(10.dp)
                    .align(Alignment.BottomEnd)
                    .clip(CircleShape)
                    .background(Color.White)
                    .clickable(onClick = onRequestHighlighted)
                    .padding(6.dp)
            )
        }
        Text(
            entry.profile.displayName,
            color = Color.White,
            fontSize = 14.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
            style = MaterialTheme.typography.labelLarge.copy(
                shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), blurRadius = 4f)
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(10.dp).align(Alignment.BottomStart)
        )
    }
}

private data class BadgeState(val text: String, val bg: Color, val fg: Color, val clickable: Boolean)

private fun distanceKmOrNull(here: Location, profile: Profile): Float? {
    val lat = profile.lastLat ?: return null
    val lng = profile.lastLng ?: return null
    val there = Location("them").apply { latitude = lat; longitude = lng }
    return here.distanceTo(there)
}
