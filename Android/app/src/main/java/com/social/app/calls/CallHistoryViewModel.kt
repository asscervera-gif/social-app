package com.social.app.calls

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Call
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
 * Historial de llamadas real, comparado con WhatsApp/Messenger/FaceTime --
 * SOCIAL ya tenía llamadas 1:1 y de grupo reales (0079_calls.sql/
 * 0083_group_calls.sql), pero ninguna pantalla mostraba quién llamó, quién
 * perdió una llamada, ni la duración real -- confirmado en el propio
 * código (`grep` de "historial de llamadas"/"call history" sin resultados
 * en todo el repo). Sin migración: `calls` ya tiene todo lo necesario
 * (caller_id/callee_id/group_chat_id/status/created_at/ended_at),
 * `calls_select` (última versión real: 0083) ya restringe a quien
 * participó de verdad -- una consulta sin filtro extra ya solo devuelve
 * mis propias llamadas (1:1 o de grupo), sin necesitar reconstruir esa
 * lógica en el cliente.
 */
class CallHistoryViewModel : ViewModel() {

    data class CallEntry(
        val call: Call,
        val isOutgoing: Boolean,
        val otherName: String,
        val isGroup: Boolean
    )

    private val _entries = MutableStateFlow<List<CallEntry>>(emptyList())
    val entries: StateFlow<List<CallEntry>> = _entries.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            _isLoading.value = true
            try {
                val myId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val calls = SupabaseManager.client.from("calls")
                    .select {
                        order("created_at", Order.DESCENDING)
                        limit(100)
                    }
                    .decodeList<Call>()

                val otherIds = calls.mapNotNull { if (it.callerId == myId) it.calleeId else it.callerId }.distinct()
                val profiles = if (otherIds.isEmpty()) emptyMap() else try {
                    SupabaseManager.client.from("profiles")
                        .select(columns = Columns.raw("id,display_name,avatar_url,avatar_config")) {
                            filter { isIn("id", otherIds) }
                        }
                        .decodeList<Profile>()
                        .associateBy { it.id }
                } catch (e: Exception) {
                    emptyMap()
                }

                val groupIds = calls.mapNotNull { it.groupChatId }.distinct()
                val groupNames = if (groupIds.isEmpty()) emptyMap() else try {
                    SupabaseManager.client.from("group_chats")
                        .select(columns = Columns.raw("id,name")) { filter { isIn("id", groupIds) } }
                        .decodeList<GroupChatNameRow>()
                        .associate { it.id to it.name }
                } catch (e: Exception) {
                    emptyMap()
                }

                _entries.value = calls.map { call ->
                    val isGroup = call.groupChatId != null
                    val isOutgoing = call.callerId == myId
                    val otherName = if (isGroup) {
                        groupNames[call.groupChatId] ?: "Grupo"
                    } else {
                        val otherId = if (isOutgoing) call.calleeId else call.callerId
                        profiles[otherId]?.displayName ?: "Perfil"
                    }
                    CallEntry(call, isOutgoing, otherName, isGroup)
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cargar el historial de llamadas."
            } finally {
                _isLoading.value = false
            }
        }
    }

    @Serializable
    private data class GroupChatNameRow(val id: String, val name: String)
}
