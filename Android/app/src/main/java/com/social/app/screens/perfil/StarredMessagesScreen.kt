package com.social.app.screens.perfil

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Profile
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Mensajes destacados ("Starred messages"), comparado con WhatsApp --
 * comprobado en el propio código: `grep` de "starred"/"destacad"/
 * "favorit" en todo el repo no encontró nada, el único mecanismo parecido
 * (`saved_posts`, ver SavedPostsScreen.kt) es para publicaciones, no para
 * mensajes de chat. Mismo patrón exacto: tabla propia, RLS privada,
 * pantalla propia (0087_starred_messages.sql).
 *
 * Referencia real polimórfica: un destacado viene de `messages` (1:1) O de
 * `group_messages` (grupo), nunca los dos -- se resuelven ambos embeds en
 * una sola consulta real de PostgREST y se aplanan aquí mismo en un solo
 * modelo de UI.
 */
data class StarredEntry(
    val starId: String,
    val isGroup: Boolean,
    val chatId: String?,
    val groupChatId: String?,
    val senderId: String,
    val body: String?,
    val createdAt: String
)

class StarredMessagesViewModel : ViewModel() {
    private val _entries = MutableStateFlow<List<StarredEntry>>(emptyList())
    val entries: StateFlow<List<StarredEntry>> = _entries.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _senderProfiles = MutableStateFlow<Map<String, Profile>>(emptyMap())
    val senderProfiles: StateFlow<Map<String, Profile>> = _senderProfiles.asStateFlow()

    @Serializable
    private data class MessageEmbed(
        @SerialName("chat_id") val chatId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String? = null
    )

    @Serializable
    private data class GroupMessageEmbed(
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String? = null
    )

    @Serializable
    private data class StarredRow(
        val id: String,
        @SerialName("created_at") val createdAt: String,
        val messages: MessageEmbed? = null,
        @SerialName("group_messages") val groupMessages: GroupMessageEmbed? = null
    )

    fun load() {
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val rows = SupabaseManager.client.from("starred_messages")
                    .select(
                        columns = Columns.raw(
                            "id,created_at,messages(chat_id,sender_id,body),group_messages(group_chat_id,sender_id,body)"
                        )
                    ) {
                        filter { eq("user_id", userId) }
                        order("created_at", Order.DESCENDING)
                    }
                    .decodeList<StarredRow>()

                _entries.value = rows.mapNotNull { row ->
                    val direct = row.messages
                    val group = row.groupMessages
                    when {
                        direct != null -> StarredEntry(row.id, false, direct.chatId, null, direct.senderId, direct.body, row.createdAt)
                        group != null -> StarredEntry(row.id, true, null, group.groupChatId, group.senderId, group.body, row.createdAt)
                        else -> null
                    }
                }

                val senderIds = _entries.value.map { it.senderId }.distinct()
                if (senderIds.isNotEmpty()) {
                    try {
                        _senderProfiles.value = SupabaseManager.client.from("profiles")
                            .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                                filter { isIn("id", senderIds) }
                            }
                            .decodeList<Profile>()
                            .associateBy { it.id }
                    } catch (e: Exception) {
                        // No bloquea el resto de la lista si falla.
                    }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar tus mensajes destacados."
            }
        }
    }

    /** Quitar de destacados desde esta misma lista -- mismo criterio que
     * SavedPostsViewModel.unsave(). */
    fun unstar(entry: StarredEntry) {
        _entries.value = _entries.value.filter { it.starId != entry.starId }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("starred_messages").delete { filter { eq("id", entry.starId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo quitar el destacado."
            }
        }
    }
}

@Composable
fun StarredMessagesScreen(
    viewModel: StarredMessagesViewModel = viewModel(),
    onOpenChat: (String) -> Unit = {},
    onOpenGroupChat: (String) -> Unit = {}
) {
    val entries by viewModel.entries.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val senderProfiles by viewModel.senderProfiles.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Mensajes destacados", style = MaterialTheme.typography.headlineSmall)
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (entries.isEmpty() && errorMessage == null) {
            Text(
                "Todavía no has destacado ningún mensaje.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(entries, key = { it.starId }) { entry ->
                val sender = senderProfiles[entry.senderId]
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 10.dp)
                        .clickable {
                            if (entry.isGroup) entry.groupChatId?.let(onOpenGroupChat)
                            else entry.chatId?.let(onOpenChat)
                        }
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        com.social.app.avatar.AvatarView(config = sender?.avatarConfig ?: emptyMap(), size = 24.dp)
                        Text(
                            sender?.displayName ?: "…",
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier.padding(start = 6.dp)
                        )
                    }
                    Text(
                        entry.body ?: "",
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(top = 4.dp)
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            if (entry.isGroup) "En un grupo" else "En un chat",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        OutlinedButton(onClick = { viewModel.unstar(entry) }) { Text("Quitar") }
                    }
                }
                HorizontalDivider()
            }
        }
    }
}
