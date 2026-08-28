package com.social.app.screens.perfil

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.ScreenTimeManager
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.LocalDate

/**
 * "Tiempo en pantalla" real ("Bienestar digital"), comparado con
 * Instagram ("Tu actividad")/TikTok (Screen Time Management)/Facebook
 * ("Tu tiempo en Facebook")/Snapchat -- ver ScreenTimeManager.kt,
 * 0149_screen_time.sql.
 */
class ScreenTimeViewModel : ViewModel() {
    private val _dailyMinutes = MutableStateFlow<Map<LocalDate, Int>>(emptyMap())
    val dailyMinutes: StateFlow<Map<LocalDate, Int>> = _dailyMinutes.asStateFlow()

    private val _limitMinutes = MutableStateFlow<Int?>(null)
    val limitMinutes: StateFlow<Int?> = _limitMinutes.asStateFlow()

    private val _reminderEnabled = MutableStateFlow(false)
    val reminderEnabled: StateFlow<Boolean> = _reminderEnabled.asStateFlow()

    @Serializable
    private data class LimitRow(
        @SerialName("daily_time_limit_minutes") val dailyTimeLimitMinutes: Int? = null,
        @SerialName("daily_reminder_enabled") val dailyReminderEnabled: Boolean = false
    )

    fun load() {
        viewModelScope.launch {
            _dailyMinutes.value = ScreenTimeManager.loadLastSevenDays()
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                val row = SupabaseManager.client.from("profiles")
                    .select { filter { eq("id", userId) } }
                    .decodeSingle<LimitRow>()
                _limitMinutes.value = row.dailyTimeLimitMinutes
                _reminderEnabled.value = row.dailyReminderEnabled
            } catch (e: Exception) {
                // No crítico -- la gráfica sigue siendo útil sin límite.
            }
        }
    }

    fun setLimit(minutes: Int?, reminderEnabled: Boolean) {
        _limitMinutes.value = minutes
        _reminderEnabled.value = reminderEnabled
        viewModelScope.launch {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@launch
            try {
                SupabaseManager.client.from("profiles").update({
                    set("daily_time_limit_minutes", minutes)
                    set("daily_reminder_enabled", reminderEnabled)
                }) { filter { eq("id", userId) } }
            } catch (e: Exception) {
                // No crítico.
            }
        }
    }
}

@Composable
fun ScreenTimeScreen(viewModel: ScreenTimeViewModel = viewModel()) {
    val dailyMinutes by viewModel.dailyMinutes.collectAsState()
    val limitMinutes by viewModel.limitMinutes.collectAsState()
    val reminderEnabled by viewModel.reminderEnabled.collectAsState()
    var limitInput by remember(limitMinutes) { mutableStateOf(limitMinutes?.toString() ?: "") }

    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Tiempo en pantalla", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Últimos 7 días reales en SOCIAL.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp)
        )

        val days = (6 downTo 0).map { LocalDate.now().minusDays(it.toLong()) }
        val maxMinutes = (days.maxOfOrNull { dailyMinutes[it] ?: 0 } ?: 0).coerceAtLeast(1)
        Row(
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth().height(140.dp).padding(top = 20.dp)
        ) {
            days.forEach { day ->
                val minutes = dailyMinutes[day] ?: 0
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.weight(1f)) {
                    Text("${minutes}m", style = MaterialTheme.typography.labelSmall)
                    Box(
                        modifier = Modifier
                            .width(20.dp)
                            .height((100 * minutes / maxMinutes).coerceAtLeast(2).dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(MaterialTheme.colorScheme.primary)
                    )
                    Text(day.dayOfWeek.name.take(3), style = MaterialTheme.typography.labelSmall)
                }
            }
        }

        Text("Límite diario", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 24.dp))
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.padding(end = 12.dp)) {
                Text("Recordatorio real al superar el límite")
                Text(
                    "Aviso local, sin bloquear el uso de la app.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(checked = reminderEnabled, onCheckedChange = { checked ->
                viewModel.setLimit(limitInput.toIntOrNull(), checked)
            })
        }
        OutlinedTextField(
            value = limitInput,
            onValueChange = { limitInput = it.filter { c -> c.isDigit() } },
            label = { Text("Minutos por día") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
        )
        Button(
            onClick = { viewModel.setLimit(limitInput.toIntOrNull(), reminderEnabled) },
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp)
        ) {
            Text("Guardar")
        }
    }
}
