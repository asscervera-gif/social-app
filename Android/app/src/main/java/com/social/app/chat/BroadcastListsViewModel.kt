package com.social.app.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class BroadcastList(val id: String, val name: String)

data class BroadcastMember(val id: String, val displayName: String)

/**
 * Listas de difusión reales, comparado con WhatsApp -- mandar el mismo
 * mensaje real a varias personas de un tirón, cada una lo recibe como un
 * mensaje 1:1 NORMAL en su propio chat, sin enterarse de quién más lo
 * recibió ni de que la lista existe (a diferencia de un chat de grupo).
 * Deliberadamente sin ninguna tabla de "mensaje de difusión": mandar es,
 * para el propio backend, sencillamente un INSERT normal en `messages`
 * por cada destinatario (chat 1:1 real, reutilizando
 * SocialLinkManager.getOrCreateChat ya construido). Ver
 * 0103_broadcast_lists.sql.
 */
class BroadcastListsViewModel : ViewModel() {

    private val socialLinks = SocialLinkManager()

    private val _lists = MutableStateFlow<List<BroadcastList>>(emptyList())
    val lists: StateFlow<List<BroadcastList>> = _lists.asStateFlow()

    private val _members = MutableStateFlow<List<BroadcastMember>>(emptyList())
    val members: StateFlow<List<BroadcastMember>> = _members.asStateFlow()

    // Gente que sigo, la fuente real más cercana a "tus contactos" de
    // WhatsApp que ya existe en SOCIAL -- mismo criterio que el resto de
    // pantallas de esta sesión que necesitan elegir entre "gente
    // conocida" (p. ej. mejores amigos, 0075).
    private val _myFollowing = MutableStateFlow<List<BroadcastMember>>(emptyList())
    val myFollowing: StateFlow<List<BroadcastMember>> = _myFollowing.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _sendResult = MutableStateFlow<String?>(null)
    val sendResult: StateFlow<String?> = _sendResult.asStateFlow()

    @Serializable
    private data class FollowRow(@SerialName("followee_id") val followeeId: String)

    @Serializable
    private data class NameRow(val id: String, @SerialName("display_name") val displayName: String)

    fun load() {
        viewModelScope.launch {
            try {
                _lists.value = SupabaseManager.client.from("broadcast_lists")
                    .select(columns = Columns.raw("id,name"))
                    .decodeList<BroadcastList>()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las listas de difusión."
            }
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val followingIds = SupabaseManager.client.from("follows")
                    .select(columns = Columns.raw("followee_id")) { filter { eq("follower_id", userId) } }
                    .decodeList<FollowRow>()
                    .map { it.followeeId }
                _myFollowing.value = if (followingIds.isEmpty()) emptyList() else {
                    SupabaseManager.client.from("profiles")
                        .select(columns = Columns.raw("id,display_name")) { filter { isIn("id", followingIds) } }
                        .decodeList<NameRow>()
                        .map { BroadcastMember(it.id, it.displayName) }
                }
            } catch (e: Exception) {
                _myFollowing.value = emptyList()
            }
        }
    }

    @Serializable
    private data class NewBroadcastList(
        @SerialName("owner_id") val ownerId: String,
        val name: String
    )

    fun createList(name: String) {
        val trimmed = name.trim().take(50)
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            try {
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
                val created = SupabaseManager.client.from("broadcast_lists")
                    .insert(NewBroadcastList(userId, trimmed)) { select() }
                    .decodeSingle<BroadcastList>()
                _lists.update { it + created }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo crear la lista."
            }
        }
    }

    fun deleteList(listId: String) {
        _lists.update { list -> list.filter { it.id != listId } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("broadcast_lists").delete { filter { eq("id", listId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo borrar la lista."
            }
        }
    }

    fun loadMembers(listId: String) {
        viewModelScope.launch {
            try {
                val memberIds = SupabaseManager.client.from("broadcast_list_members")
                    .select(columns = Columns.raw("member_id")) { filter { eq("broadcast_list_id", listId) } }
                    .decodeList<MemberIdRow>()
                    .map { it.memberId }
                _members.value = if (memberIds.isEmpty()) emptyList() else {
                    SupabaseManager.client.from("profiles")
                        .select(columns = Columns.raw("id,display_name")) { filter { isIn("id", memberIds) } }
                        .decodeList<NameRow>()
                        .map { BroadcastMember(it.id, it.displayName) }
                }
            } catch (e: Exception) {
                _members.value = emptyList()
            }
        }
    }

    @Serializable
    private data class MemberIdRow(@SerialName("member_id") val memberId: String)

    @Serializable
    private data class NewMember(
        @SerialName("broadcast_list_id") val broadcastListId: String,
        @SerialName("member_id") val memberId: String
    )

    fun addMember(listId: String, memberId: String, displayName: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("broadcast_list_members").insert(NewMember(listId, memberId))
                _members.update { it + BroadcastMember(memberId, displayName) }
            } catch (e: Exception) {
                // Bloqueado real (en cualquier dirección) u otro fallo --
                // mismo criterio de no forzar un estado optimista que
                // luego habría que deshacer.
                _errorMessage.value = "No se pudo añadir a esa persona (¿os habéis bloqueado?)."
            }
        }
    }

    fun removeMember(listId: String, memberId: String) {
        _members.update { list -> list.filter { it.id != memberId } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("broadcast_list_members").delete {
                    filter { eq("broadcast_list_id", listId); eq("member_id", memberId) }
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo quitar a esa persona."
            }
        }
    }

    @Serializable
    private data class NewMessage(
        @SerialName("chat_id") val chatId: String,
        @SerialName("sender_id") val senderId: String,
        val body: String
    )

    /** Manda el mismo mensaje real, uno por uno, como un mensaje 1:1
     * normal a cada miembro real de la lista -- ni una tabla ni un
     * concepto de "mensaje de difusión" en el servidor, mismo criterio
     * real que WhatsApp de verdad (cada copia vive independiente en su
     * propio chat). Bloqueados reales se saltan en silencio (mismo
     * criterio que WhatsApp: la persona bloqueada nunca se entera de
     * nada) -- `messages_insert` ya lo impide por sí sola. */
    fun sendBroadcast(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || trimmed.length > 2000) return
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            val targets = _members.value
            var sentCount = 0
            for (member in targets) {
                try {
                    val chatId = socialLinks.getOrCreateChat(userId, member.id) ?: continue
                    SupabaseManager.client.from("messages").insert(NewMessage(chatId, userId, trimmed))
                    sentCount++
                } catch (e: Exception) {
                    // Bloqueado real u otro fallo puntual -- se sigue
                    // mandando al resto real de la lista, no se aborta
                    // todo por una sola persona.
                }
            }
            _sendResult.value = "Mandado a $sentCount de ${targets.size} personas reales."
        }
    }

    fun clearSendResult() {
        _sendResult.value = null
    }
}
