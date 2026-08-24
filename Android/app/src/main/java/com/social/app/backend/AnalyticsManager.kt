package com.social.app.backend

import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Analítica mínima auto-alojada en la propia tabla Supabase del proyecto —
 * deliberadamente NO se integra un SDK de terceros (Firebase Analytics,
 * Mixpanel, etc.): la tabla `analytics_events` (0005_analytics.sql) y la
 * función `event_density()` ya cubren la única métrica que
 * growth_strategy.md identifica como la que de verdad importa para un
 * producto con umbral físico — densidad efectiva por evento — sin añadir
 * una dependencia de pago ni un tracker de comportamiento genérico.
 *
 * Fire-and-forget deliberado: un fallo de red al registrar un evento nunca
 * debe afectar a la funcionalidad real de la app (mismo principio que el
 * try/catch silencioso de loadBlockedPeers en SocialCameraScreen.kt).
 */
object AnalyticsManager {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Hallazgo real: `event_density()` (0005_analytics.sql) cuenta actividad
     * reciente filtrando `analytics_events` por `event_id`, pero `tab_view`/
     * `app_open` — los únicos eventos que se disparan repetidamente mientras
     * alguien sigue usando la app — nunca llevaban `event_id`. Solo
     * `event_joined` lo llevaba, una vez. Resultado: la métrica que
     * `growth_strategy.md` señala como la única que importa medía "gente
     * que se acaba de unir", no "gente todavía activa".
     *
     * Corregido con este holder en memoria (mismo patrón de singleton que
     * `SupabaseManager`, sin necesidad de compartir estado de Compose entre
     * `EventModeViewModel` y `RootTabView.kt`): `EventModeViewModel.joinEvent()`
     * lo fija tras un `event_joined` real (no solo por detectar el evento
     * cerca — `hasJoined` es la señal correcta, no `activeEvent`), y `track()`
     * lo usa automáticamente como `event_id` para cualquier llamada que no
     * pase uno explícito. Se limpia en `RootTabView` si el usuario cambia de
     * evento o deja de estar en uno — ver `clearCurrentEvent()`.
     */
    @Volatile
    var currentEventId: String? = null
        private set

    fun setCurrentEvent(eventId: String?) {
        currentEventId = eventId
    }

    @Serializable
    private data class NewEvent(
        @SerialName("profile_id") val profileId: String? = null,
        @SerialName("event_type") val eventType: String,
        @SerialName("event_id") val eventId: String? = null
    )

    fun track(eventType: String, eventId: String? = null) {
        scope.launch {
            try {
                val profileId = SupabaseManager.client.auth.currentUserOrNull()?.id
                SupabaseManager.client.from("analytics_events").insert(
                    NewEvent(profileId = profileId, eventType = eventType, eventId = eventId ?: currentEventId)
                )
            } catch (e: Exception) {
                // Ver comentario de clase: nunca debe romper la app.
            }
        }
    }
}
