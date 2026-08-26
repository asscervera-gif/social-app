package com.social.app.calls

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.social.app.backend.SupabaseManager
import com.social.app.backend.model.Call
import com.social.app.backend.model.CallParticipant
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import io.github.jan.supabase.realtime.realtime
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Videollamada/llamada de voz 1:1 real (0079_calls.sql), comparado con
 * WhatsApp/Messenger/Instagram -- las tres dejan llamar directamente
 * desde un chat privado; SOCIAL no tenía nada de esto, la única pieza de
 * vídeo en tiempo real era "En directo" (audiencia pública, LiveStreamsViewModel.kt).
 *
 * Global, montado una sola vez en RootTabView.kt (mismo criterio que
 * NotificationsBadgeViewModel.kt) -- una llamada entrante tiene que poder
 * avisar sin importar en qué pestaña esté el usuario, igual que un aviso
 * nuevo. Mismo canal por-usuario ya usado ahí (`calls-$userId`), no un
 * canal global: `legal/scaling_notes.md` documenta explícitamente que los
 * canales de Realtime de este proyecto son por chat o por usuario, nunca
 * globales, para no saturar un único canal a escala.
 *
 * Aviso de honestidad, mismo criterio que "En directo": esto SÍ detecta
 * una llamada entrante en tiempo real mientras la app está abierta (en
 * cualquier pestaña) vía Supabase Realtime -- lo que NO puede hacer sin
 * push real (APNs/FCM, ver LOOP_STATE.md "Pendiente real") es sonar con
 * la app cerrada o en segundo plano del todo, igual que las notificaciones
 * locales del resto de la app.
 */
class CallManager : ViewModel() {

    private val _activeCall = MutableStateFlow<Call?>(null)
    val activeCall: StateFlow<Call?> = _activeCall.asStateFlow()

    // Solo relevante para llamadas de GRUPO (0083_group_calls.sql): una
    // fila real por miembro del grupo, a diferencia de la 1:1 que solo
    // tiene caller/callee dentro de la propia fila de `calls`.
    private val _participants = MutableStateFlow<List<CallParticipant>>(emptyList())
    val participants: StateFlow<List<CallParticipant>> = _participants.asStateFlow()

    private var channel: RealtimeChannel? = null
    private var participantsChannel: RealtimeChannel? = null
    private var myId: String? = null

    fun start() {
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            myId = userId
            subscribeToRealtime(userId)
        }
    }

    fun stop() {
        viewModelScope.launch {
            channel?.unsubscribe()
            participantsChannel?.unsubscribe()
        }
    }

    /** El usuario ya vio el estado final (aceptada y en curso en su propia
     * pantalla de llamada, o rechazada/colgada/perdida) -- limpia el
     * estado local. Deliberadamente NO automático dentro de este
     * ViewModel: temporizar el borrado aquí mismo competiría de verdad
     * con el eco de Realtime de la propia actualización, pudiendo
     * resucitar una llamada ya cerrada -- la pantalla decide cuándo. */
    fun dismiss() {
        _activeCall.value = null
        _participants.value = emptyList()
        viewModelScope.launch {
            participantsChannel?.unsubscribe()
            participantsChannel = null
        }
    }

    @Serializable
    private data class NewCall(
        @SerialName("chat_id") val chatId: String,
        @SerialName("caller_id") val callerId: String,
        @SerialName("callee_id") val calleeId: String,
        val kind: String
    )

    fun startCall(chatId: String, calleeId: String, kind: String) {
        viewModelScope.launch {
            val userId = myId ?: return@launch
            if (_activeCall.value != null) return@launch
            try {
                val call = SupabaseManager.client.from("calls")
                    .insert(NewCall(chatId, userId, calleeId, kind)) { select() }
                    .decodeSingle<Call>()
                _activeCall.value = call
            } catch (e: Exception) {
                // No se pudo iniciar -- se queda sin llamada activa, mismo
                // criterio de "falla en silencio, sin romper el resto del
                // chat" ya aplicado a activity-ai/icebreaker-ai.
            }
        }
    }

    fun accept() = updateStatus("accepted")
    fun decline() = updateStatus("declined")
    fun cancelOutgoing() = updateStatus("ended")

    @Serializable
    private data class NewGroupCall(
        @SerialName("group_chat_id") val groupChatId: String,
        @SerialName("caller_id") val callerId: String,
        val kind: String
    )

    /** Videollamada de GRUPO real (0083_group_calls.sql), comparado con
     * WhatsApp/Messenger/Telegram -- a diferencia de startCall() (1:1), no
     * hay un único destinatario que la acepte primero: el propio emisor
     * queda ya 'accepted' de inmediato (populate_call_participants lo
     * garantiza también del lado del servidor). */
    fun startGroupCall(groupChatId: String, kind: String) {
        viewModelScope.launch {
            val userId = myId ?: return@launch
            if (_activeCall.value != null) return@launch
            try {
                val call = SupabaseManager.client.from("calls")
                    .insert(NewGroupCall(groupChatId, userId, kind)) { select() }
                    .decodeSingle<Call>()
                // El RETURNING de este INSERT todavía refleja 'ringing'
                // (el valor por defecto de la columna, antes de que el
                // trigger AFTER INSERT la corrija con un UPDATE aparte --
                // RETURNING nunca ve cambios de un trigger AFTER sobre
                // otra sentencia, mismo hallazgo real documentado en
                // test_rls.mjs) -- se corrige aquí mismo en vez de hacer
                // una segunda ida y vuelta de red solo para confirmar algo
                // que el propio diseño del servidor ya garantiza.
                val liveCall = call.copy(status = "accepted")
                _activeCall.value = liveCall
                loadParticipants(liveCall.id)
                subscribeToParticipants(liveCall.id)
            } catch (e: Exception) {
                // Falla en silencio, mismo criterio que startCall().
            }
        }
    }

    fun acceptGroupCall() {
        val call = _activeCall.value ?: return
        val userId = myId ?: return
        _participants.update { list -> list.map { if (it.userId == userId) it.copy(status = "accepted") else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("call_participants").update({
                    set("status", "accepted")
                    set("joined_at", java.time.Instant.now().toString())
                }) { filter { eq("call_id", call.id); eq("user_id", userId) } }
            } catch (e: Exception) {
                // No crítico.
            }
        }
    }

    fun declineGroupCall() {
        val call = _activeCall.value ?: return
        val userId = myId ?: return
        _participants.update { list -> list.map { if (it.userId == userId) it.copy(status = "declined") else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("call_participants")
                    .update({ set("status", "declined") }) { filter { eq("call_id", call.id); eq("user_id", userId) } }
            } catch (e: Exception) {
                // No crítico.
            }
        }
    }

    /** Colgar MI PROPIA participación real en una llamada de grupo --
     * a diferencia de end() (1:1), esto nunca termina la llamada para el
     * resto: cada participante sale por su cuenta, mismo criterio que
     * WhatsApp/Messenger. */
    fun leaveGroupCall() {
        val call = _activeCall.value ?: return
        val userId = myId ?: return
        _participants.update { list -> list.map { if (it.userId == userId) it.copy(status = "ended") else it } }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("call_participants").update({
                    set("status", "ended")
                    set("left_at", java.time.Instant.now().toString())
                }) { filter { eq("call_id", call.id); eq("user_id", userId) } }
            } catch (e: Exception) {
                // No crítico.
            }
        }
    }

    private suspend fun loadParticipants(callId: String) {
        try {
            val rows = SupabaseManager.client.from("call_participants")
                .select { filter { eq("call_id", callId) } }
                .decodeList<CallParticipant>()
            _participants.value = rows
        } catch (e: Exception) {
            // Se queda vacía -- IncomingGroupCallScreen/LiveGroupCallScreen
            // simplemente no tendrán roster hasta que Realtime traiga algo.
        }
    }

    /** Canal real acotado a UNA llamada de grupo concreta (no global, no
     * por-usuario): mismo criterio de "nunca un canal global" que el resto
     * de este archivo, pero aquí hace falta ver el estado de TODOS los
     * participantes reales de esta llamada (quién se unió/rechazó/salió),
     * no solo el propio -- se crea al entrar en la llamada y se destruye
     * al salir (dismiss()/el siguiente startGroupCall()). */
    private fun subscribeToParticipants(callId: String) {
        viewModelScope.launch { participantsChannel?.unsubscribe() }
        val ch = SupabaseManager.client.realtime.channel("call-participants-$callId")
        participantsChannel = ch
        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "call_participants"
            filter("call_id", FilterOperator.EQ, callId)
        }.onEach { update ->
            val updated = Json.decodeFromJsonElement(CallParticipant.serializer(), update.record)
            _participants.update { list -> list.map { if (it.userId == updated.userId) updated else it } }
        }.launchIn(viewModelScope)
        viewModelScope.launch { ch.subscribe() }
    }

    fun end() {
        val call = _activeCall.value ?: return
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("calls").update({
                    set("status", "ended")
                    set("ended_at", java.time.Instant.now().toString())
                }) { filter { eq("id", call.id) } }
            } catch (e: Exception) {
                // No crítico: la sala de LiveKit ya se desconecta en
                // cliente independientemente de si esto llega a guardarse.
            }
        }
    }

    @Serializable
    data class LiveKitTokenResponse(val token: String, val wsUrl: String, val roomName: String)

    @Serializable
    private data class TokenRequest(val callId: String)

    /** Mismo patrón exacto que LiveStreamsViewModel.kt.requestToken() --
     * solo se emite un token real cuando la llamada YA está `accepted`
     * de verdad en la base de datos (comprobado en call-token/index.ts,
     * nunca confiado al cliente). */
    suspend fun requestToken(callId: String): LiveKitTokenResponse? {
        return try {
            val response = SupabaseManager.client.functions.invoke("call-token", body = TokenRequest(callId))
            Json.decodeFromString(response.bodyAsText())
        } catch (e: Exception) {
            null
        }
    }

    private fun updateStatus(status: String) {
        val call = _activeCall.value ?: return
        _activeCall.value = call.copy(status = status)
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("calls")
                    .update({ set("status", status) }) { filter { eq("id", call.id) } }
            } catch (e: Exception) {
                // No crítico.
            }
        }
    }

    private fun subscribeToRealtime(userId: String) {
        val ch = SupabaseManager.client.realtime.channel("calls-$userId")
        channel = ch

        // Alguien me está llamando de verdad ahora mismo -- ignora una
        // segunda llamada entrante mientras ya hay una activa (mismo
        // criterio simple que "ocupado" en cualquier app de llamadas).
        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "calls"
            filter("callee_id", FilterOperator.EQ, userId)
        }.onEach { insert ->
            if (_activeCall.value != null) return@onEach
            val call = Json.decodeFromJsonElement(Call.serializer(), insert.record)
            if (call.status == "ringing") _activeCall.value = call
        }.launchIn(viewModelScope)

        // La otra parte aceptó/rechazó/colgó una llamada que YO inicié.
        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "calls"
            filter("caller_id", FilterOperator.EQ, userId)
        }.onEach { update ->
            val call = Json.decodeFromJsonElement(Call.serializer(), update.record)
            if (_activeCall.value?.id == call.id) _activeCall.value = call
        }.launchIn(viewModelScope)

        // Reflejar en este dispositivo un cambio de estado de una llamada
        // donde YO soy quien recibe (p. ej. la acepté desde otra sesión).
        ch.postgresChangeFlow<PostgresAction.Update>(schema = "public") {
            table = "calls"
            filter("callee_id", FilterOperator.EQ, userId)
        }.onEach { update ->
            val call = Json.decodeFromJsonElement(Call.serializer(), update.record)
            if (_activeCall.value?.id == call.id) _activeCall.value = call
        }.launchIn(viewModelScope)

        // Llamada de GRUPO entrante real (0083_group_calls.sql): mi propia
        // fila real en call_participants se inserta en el momento de
        // crear la llamada, ya 'accepted' si soy quien llama o 'ringing'
        // si soy cualquier otro miembro real del grupo -- mismo canal
        // por-usuario que el resto de este archivo, nunca global.
        ch.postgresChangeFlow<PostgresAction.Insert>(schema = "public") {
            table = "call_participants"
            filter("user_id", FilterOperator.EQ, userId)
        }.onEach { insert ->
            val participant = Json.decodeFromJsonElement(CallParticipant.serializer(), insert.record)
            if (_activeCall.value?.id == participant.callId) return@onEach
            if (_activeCall.value != null) return@onEach
            viewModelScope.launch {
                try {
                    val call = SupabaseManager.client.from("calls")
                        .select { filter { eq("id", participant.callId) } }
                        .decodeSingle<Call>()
                    _activeCall.value = call
                    loadParticipants(call.id)
                    subscribeToParticipants(call.id)
                } catch (e: Exception) {
                    // No crítico: la llamada real sigue viva en el
                    // servidor aunque este dispositivo no la muestre.
                }
            }
        }.launchIn(viewModelScope)

        viewModelScope.launch { ch.subscribe() }
    }
}
