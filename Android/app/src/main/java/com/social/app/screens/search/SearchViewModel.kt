package com.social.app.screens.search

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Post
import com.social.app.backend.model.Profile
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Hallazgo real: comparando con Instagram/TikTok/Snapchat, las tres tienen
 * un buscador de personas por nombre — SOCIAL no tenía NINGUNA forma de
 * encontrar a alguien salvo la cámara de proximidad (UWB, solo gente
 * físicamente cerca) o la cuadrícula de Match (candidatos aleatorios, sin
 * control del usuario). `profiles_select_public` (0002_rls.sql) ya permite
 * leer nombre/avatar de cualquier perfil, así que la búsqueda es una
 * consulta directa, sin RPC ni columna nueva.
 *
 * Hallazgo real (esta pasada): las tres apps también dejan buscar por
 * etiqueta/hashtag (Explorar de Instagram, búsqueda de TikTok) — SOCIAL
 * solo buscaba personas, nunca contenido. `posts_select` (0002_rls.sql)
 * ya permite leer cualquier post público (`is_social_only = false`), así
 * que buscar por `#etiqueta` en `caption` tampoco necesita columna nueva:
 * si el texto empieza por "#", se busca en publicaciones en vez de
 * perfiles.
 */
class SearchViewModel : ViewModel() {

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    private val _results = MutableStateFlow<List<Profile>>(emptyList())
    val results: StateFlow<List<Profile>> = _results.asStateFlow()

    private val _postResults = MutableStateFlow<List<Post>>(emptyList())
    val postResults: StateFlow<List<Post>> = _postResults.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private var searchJob: Job? = null

    fun onQueryChange(text: String) {
        _query.value = text
        searchJob?.cancel()
        if (text.isBlank()) {
            _results.value = emptyList()
            _postResults.value = emptyList()
            return
        }
        // Debounce de 300ms — evita una consulta por cada letra tecleada,
        // mismo criterio de "no saturar la red" ya aplicado en otras
        // partes de la app (rate limiting de ai_usage, etc.).
        searchJob = viewModelScope.launch {
            delay(300)
            if (text.trimStart().startsWith("#")) {
                _results.value = emptyList()
                searchHashtag(text.trimStart().removePrefix("#"))
            } else {
                _postResults.value = emptyList()
                search(text)
            }
        }
    }

    private suspend fun searchHashtag(tag: String) {
        if (tag.isBlank()) {
            _postResults.value = emptyList()
            return
        }
        try {
            // Hallazgo real: a diferencia de la búsqueda de perfiles (sí
            // excluye bloqueados), esta búsqueda por hashtag no filtraba
            // publicaciones de gente que has bloqueado — RLS
            // (`posts_select`) excluye correctamente `is_social_only`,
            // pero no sabe nada de `blocks`, que es puramente un refuerzo
            // de cliente en esta app (ver Search/Home/Match/Find). Mismo
            // criterio ya aplicado en el resto de listados.
            val blockedIds = try {
                SupabaseManager.client.from("blocks")
                    .select(columns = Columns.raw("blocked_id"))
                    .decodeList<BlockRow>()
                    .map { it.blockedId }
                    .toSet()
            } catch (e: Exception) {
                emptySet()
            }
            val matches = SupabaseManager.client.from("posts")
                .select {
                    filter { ilike("caption", "%#$tag%") }
                    order("created_at", io.github.jan.supabase.postgrest.query.Order.DESCENDING)
                    limit(30)
                }
                .decodeList<Post>()
                .filter { it.authorId !in blockedIds }
            _postResults.value = matches
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo buscar."
        }
    }

    @Serializable
    private data class BlockRow(@SerialName("blocked_id") val blockedId: String)

    private suspend fun search(text: String) {
        try {
            val myId = SupabaseManager.client.auth.currentUserOrNull()?.id
            // Mismo refuerzo de privacidad ya aplicado en Match/Home: no
            // mostrar a quien he bloqueado. Solo se puede filtrar en esa
            // dirección (RLS de `blocks` no deja ver quién me bloqueó).
            val blockedIds = try {
                SupabaseManager.client.from("blocks")
                    .select(columns = Columns.raw("blocked_id"))
                    .decodeList<BlockRow>()
                    .map { it.blockedId }
                    .toSet()
            } catch (e: Exception) {
                emptySet()
            }
            val matches = SupabaseManager.client.from("profiles")
                .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config,interests,bio,is_invisible,location_public,compat_public,is_verified")) {
                    // Mismo filtro real ya aplicado en Home/Match
                    // (`eq("is_invisible", false)`) — sin esto, el modo
                    // invisible (SafetyManager.setInvisible) solo ocultaba
                    // a alguien de la cámara de proximidad, no del buscador
                    // por nombre, dejando la promesa de privacidad a medias.
                    filter {
                        ilike("display_name", "%$text%")
                        eq("is_invisible", false)
                    }
                    limit(30)
                }
                .decodeList<Profile>()
                .filter { it.id != myId && it.id !in blockedIds }
            _results.value = matches
        } catch (e: Exception) {
            _errorMessage.value = "No se pudo buscar."
        }
    }
}
