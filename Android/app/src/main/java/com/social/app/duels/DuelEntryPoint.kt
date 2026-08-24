package com.social.app.duels

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
private data class SectionRow(
    @SerialName("section_key") val sectionKey: String,
    val content: Map<String, String>
)

/**
 * Carga las secciones públicas (o compartidas por social aceptado) del
 * oponente antes de arrancar el duelo, y solo entonces monta DuelScreen —
 * sustituye la lista vacía que RootTabView pasaba antes con un comentario
 * de pendiente. Misma tabla `profile_sections` y mismas reglas de RLS que
 * ya protegen esta consulta en el backend (Fase 2, regla 1).
 */
@Composable
fun DuelEntryPoint(chatId: String, opponentId: String) {
    var sections by remember { mutableStateOf<List<Pair<String, Map<String, String>>>?>(null) }

    LaunchedEffect(opponentId) {
        sections = try {
            // Optimización: solo se usan section_key y content para generar
            // las preguntas del duelo, no id/profile_id/is_public.
            SupabaseManager.client.from("profile_sections")
                .select(columns = Columns.raw("section_key,content")) { filter { eq("profile_id", opponentId) } }
                .decodeList<SectionRow>()
                .map { it.sectionKey to it.content }
        } catch (e: Exception) {
            emptyList()
        }
    }

    val loaded = sections
    if (loaded == null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
    } else {
        DuelScreen(chatId = chatId, opponentId = opponentId, opponentSections = loaded)
    }
}
