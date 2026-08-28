package com.social.app.backend

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant

/**
 * Tiempo en pantalla real ("Bienestar digital"), comparado con Instagram
 * ("Tu actividad")/TikTok (Screen Time Management)/Facebook ("Tu tiempo
 * en Facebook")/Snapchat -- hueco real, confirmado con grep de
 * "screen_time|time_limit|daily_limit|usage_time" sin resultados en todo
 * el repo. `AnalyticsManager.track()` ya registraba eventos puntuales,
 * pero nunca CUÁNTO tiempo real pasa alguien dentro de la app.
 *
 * Alcance deliberadamente acotado: SIN pg_cron ni bloqueo real del uso
 * al llegar al límite (eso necesitaría APIs nativas de Screen Time/
 * Family Controls, fuera de alcance aquí) -- solo un recordatorio local
 * real cuando este mismo cliente detecta que ya se pasó el límite diario
 * configurado, mismo criterio de "límite blando" real. Llamado desde
 * MainActivity.onStart()/onStop() -- una fila real de app_sessions por
 * cada vez que la app pasa a primer plano hasta que vuelve a segundo
 * plano, ver 0149_screen_time.sql.
 */
object ScreenTimeManager {
    private const val CHANNEL_ID = "screen_time"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var currentSessionId: String? = null
    private var sessionStartedAt: Instant? = null

    @Serializable
    private data class NewSession(
        @SerialName("user_id") val userId: String,
        @SerialName("started_at") val startedAt: String
    )

    @Serializable
    private data class SessionIdRow(val id: String)

    fun startSession() {
        scope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            val now = Instant.now()
            sessionStartedAt = now
            try {
                val row = SupabaseManager.client.from("app_sessions")
                    .insert(NewSession(userId, now.toString())) { select(columns = Columns.raw("id")) }
                    .decodeSingle<SessionIdRow>()
                currentSessionId = row.id
            } catch (e: Exception) {
                // Sin sesión registrada real -- no debe bloquear el resto
                // de la app, mismo criterio que AnalyticsManager.track().
            }
        }
    }

    fun endSession(context: Context) {
        val sessionId = currentSessionId ?: return
        val startedAt = sessionStartedAt ?: return
        currentSessionId = null
        sessionStartedAt = null
        val durationSeconds = java.time.Duration.between(startedAt, Instant.now()).seconds.toInt().coerceAtLeast(0)
        scope.launch {
            try {
                SupabaseManager.client.from("app_sessions")
                    .update({
                        set("ended_at", Instant.now().toString())
                        set("duration_seconds", durationSeconds)
                    }) { filter { eq("id", sessionId) } }
                checkDailyLimit(context)
            } catch (e: Exception) {
                // No crítico -- perder el registro de una sesión no debe
                // romper el resto de la app.
            }
        }
    }

    @Serializable
    private data class DurationRow(@SerialName("duration_seconds") val durationSeconds: Int? = null)

    @Serializable
    private data class LimitRow(
        @SerialName("daily_time_limit_minutes") val dailyTimeLimitMinutes: Int? = null,
        @SerialName("daily_reminder_enabled") val dailyReminderEnabled: Boolean = false
    )

    private suspend fun checkDailyLimit(context: Context) {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return
        val limitRow = SupabaseManager.client.from("profiles")
            .select(columns = Columns.raw("daily_time_limit_minutes,daily_reminder_enabled")) { filter { eq("id", userId) } }
            .decodeSingleOrNull<LimitRow>() ?: return
        val limitMinutes = limitRow.dailyTimeLimitMinutes ?: return
        if (!limitRow.dailyReminderEnabled) return
        val todayStart = java.time.LocalDate.now().atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toString()
        val todaySessions = SupabaseManager.client.from("app_sessions")
            .select(columns = Columns.raw("duration_seconds")) {
                filter {
                    eq("user_id", userId)
                    gte("started_at", todayStart)
                }
            }
            .decodeList<DurationRow>()
        val totalMinutes = todaySessions.sumOf { it.durationSeconds ?: 0 } / 60
        if (totalMinutes >= limitMinutes) {
            notifyLimitReached(context, totalMinutes)
        }
    }

    private fun notifyLimitReached(context: Context, totalMinutes: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS)
            != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("⏱ Límite diario alcanzado")
            .setContentText("Llevas $totalMinutes minutos reales hoy en SOCIAL.")
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        NotificationManagerCompat.from(context).notify(9100, notification)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "Bienestar digital", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Recordatorio real cuando alcanzas tu límite diario de uso"
        }
        manager.createNotificationChannel(channel)
    }

    /** Últimos 7 días reales, para la gráfica de barras de
     * ScreenTimeScreen.kt -- un `sum(duration_seconds)` agrupado por
     * fecha, calculado en el CLIENTE (sin función RPC nueva). */
    suspend fun loadLastSevenDays(): Map<java.time.LocalDate, Int> {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return emptyMap()
        val sevenDaysAgo = Instant.now().minusSeconds(7 * 24 * 3600).toString()
        val sessions = try {
            SupabaseManager.client.from("app_sessions")
                .select(columns = Columns.raw("started_at,duration_seconds")) {
                    filter { eq("user_id", userId); gte("started_at", sevenDaysAgo) }
                    order("started_at", Order.ASCENDING)
                }
                .decodeList<SessionDateRow>()
        } catch (e: Exception) {
            emptyList()
        }
        return sessions
            .filter { it.durationSeconds != null }
            .groupBy { Instant.parse(it.startedAt).atZone(java.time.ZoneOffset.UTC).toLocalDate() }
            .mapValues { (_, rows) -> rows.sumOf { it.durationSeconds ?: 0 } / 60 }
    }

    @Serializable
    private data class SessionDateRow(
        @SerialName("started_at") val startedAt: String,
        @SerialName("duration_seconds") val durationSeconds: Int? = null
    )
}
