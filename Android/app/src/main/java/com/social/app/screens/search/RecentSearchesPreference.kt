package com.social.app.screens.search

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Búsquedas recientes reales, comparado con Instagram/Twitter/TikTok --
 * las tres muestran una lista de búsquedas anteriores en cuanto se toca el
 * buscador vacío, con un toque para repetirla y una forma real de
 * borrarlas. SearchScreen.kt/SearchViewModel.kt nunca recordaban nada
 * entre sesiones. Sin columna/tabla nueva -- puramente local, mismo
 * criterio ya usado en AccentPreference/ThemeModePreference
 * (SharedPreferences + StateFlow, más simple que DataStore para una lista
 * tan pequeña).
 */
object RecentSearchesPreference {
    private const val PREFS_NAME = "social_search_prefs"
    private const val KEY_RECENT = "recent_searches"

    // Separador de control real (U+0001, no imprimible) -- no un carácter
    // que alguien pudiera escribir de verdad en una búsqueda, evita que un
    // nombre/etiqueta con ese carácter literal rompiera el split.
    private val SEPARATOR = ""
    private const val MAX_ENTRIES = 10

    private val _recent = MutableStateFlow<List<String>>(emptyList())
    val recent: StateFlow<List<String>> = _recent.asStateFlow()

    private var initialized = false

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        val stored = prefs(context).getString(KEY_RECENT, null)
        _recent.value = stored?.split(SEPARATOR)?.filter { it.isNotBlank() } ?: emptyList()
    }

    /** Guarda una búsqueda real ya ejecutada -- más reciente primero, sin
     * duplicados (una repetida sube al principio en vez de aparecer dos
     * veces), tope de [MAX_ENTRIES] mismo criterio de no dejar crecer la
     * lista sin límite. */
    fun add(context: Context, query: String) {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return
        val updated = (listOf(trimmed) + _recent.value.filterNot { it.equals(trimmed, ignoreCase = true) }).take(MAX_ENTRIES)
        _recent.value = updated
        prefs(context).edit().putString(KEY_RECENT, updated.joinToString(SEPARATOR)).apply()
    }

    fun clear(context: Context) {
        _recent.value = emptyList()
        prefs(context).edit().remove(KEY_RECENT).apply()
    }
}
