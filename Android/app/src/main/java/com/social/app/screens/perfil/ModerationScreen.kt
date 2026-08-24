package com.social.app.screens.perfil

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
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.postgrest.rpc
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class ReportEntry(
    val id: String,
    @SerialName("reporter_id") val reporterId: String,
    @SerialName("reported_id") val reportedId: String,
    val reason: String,
    val details: String? = null,
    val status: String,
    @SerialName("created_at") val createdAt: String,
    val reporterName: String? = null,
    val reportedName: String? = null
)

/**
 * Panel de moderación real (primera pieza) — hallazgo documentado desde
 * hace muchas pasadas en LOOP_STATE.md: `reports` existía, tenía RLS, el
 * cliente ya insertaba denuncias reales, pero nadie podía leerlas nunca
 * sin entrar a la base de datos con una clave privilegiada
 * (`reports_select_admin`/`is_admin`, 0036_admin_moderation.sql, cierran
 * ese hueco del lado del servidor). Esta pantalla es solo visible para
 * quien tenga `profiles.is_admin = true` — una columna protegida por
 * trigger igual que `is_verified`, nunca autoconcedible por el cliente,
 * concedida a mano por `service_role` fuera de esta app.
 */
class ModerationViewModel : ViewModel() {
    private val _reports = MutableStateFlow<List<ReportEntry>>(emptyList())
    val reports: StateFlow<List<ReportEntry>> = _reports.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    @Serializable
    private data class NameRow(@SerialName("display_name") val displayName: String)

    private suspend fun nameFor(userId: String): String? = try {
        SupabaseManager.client.from("profiles")
            .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("display_name")) {
                filter { eq("id", userId) }
            }
            .decodeSingleOrNull<NameRow>()?.displayName
    } catch (e: Exception) {
        null
    }

    fun load() {
        viewModelScope.launch {
            try {
                // Si quien llama no es admin de verdad, `reports_select_admin`
                // simplemente devuelve cero filas — no hace falta comprobar
                // `is_admin` aquí también, RLS ya es la fuente de verdad.
                //
                // Hallazgo real: una denuncia sin resolver quién denunció a
                // quién es inútil para un moderador — `reports` tiene DOS
                // columnas que referencian `profiles` (reporter_id/
                // reported_id), mismo patrón sin join embebido/FK ambigua
                // ya usado en DuelHistoryViewModel/SocialsListViewModel.
                val rows = SupabaseManager.client.from("reports")
                    .select {
                        filter { eq("status", "open") }
                        order("created_at", Order.DESCENDING)
                        limit(100)
                    }
                    .decodeList<ReportEntry>()
                _reports.value = rows.map { entry ->
                    entry.copy(
                        reporterName = nameFor(entry.reporterId),
                        reportedName = nameFor(entry.reportedId)
                    )
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las denuncias."
            }
        }
    }

    fun setStatus(reportId: String, status: String) {
        _reports.value = _reports.value.filter { it.id != reportId }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("reports")
                    .update({ set("status", status) }) { filter { eq("id", reportId) } }
                com.social.app.backend.AnalyticsManager.track("report_$status")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo actualizar la denuncia."
                load()
            }
        }
    }

    @Serializable
    private data class BanParams(
        @SerialName("p_target_id") val targetId: String,
        @SerialName("p_banned") val banned: Boolean,
        @SerialName("p_until") val until: String? = null,
        @SerialName("p_reason") val reason: String? = null
    )

    /** Segunda pieza real de moderación (0037_admin_ban.sql): hasta esta
     * pasada un admin podía leer y descartar denuncias, pero no tenía
     * ninguna acción real contra el usuario denunciado — leer que alguien
     * fue denunciado 20 veces y no poder hacer nada al respecto. La
     * autorización real vive en `admin_ban_user()` (comprueba `is_admin`
     * del llamante server-side antes de escribir nada); si esta llamada
     * llega desde un cliente sin permisos, el RPC lanza una excepción
     * real (no una revocación silenciosa, porque no es una columna
     * protegida por trigger sino una función con `raise exception`). */
    fun banReportedUser(reportId: String, reportedId: String, reason: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.postgrest.rpc(
                    "admin_ban_user",
                    BanParams(targetId = reportedId, banned = true, reason = reason)
                )
                com.social.app.backend.AnalyticsManager.track("user_banned")
                setStatus(reportId, "reviewed")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo banear a este usuario."
            }
        }
    }
}

@Composable
fun ModerationScreen(viewModel: ModerationViewModel = viewModel()) {
    val reports by viewModel.reports.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Moderación", style = MaterialTheme.typography.headlineSmall)
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (reports.isEmpty() && errorMessage == null) {
            Text(
                "No hay denuncias abiertas.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 12.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(reports, key = { it.id }) { report ->
                Column(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                    Text(
                        "${report.reporterName ?: "Perfil"} → ${report.reportedName ?: "Perfil"}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(report.reason, style = MaterialTheme.typography.titleSmall)
                    report.details?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                    Row(modifier = Modifier.fillMaxWidth().padding(top = 6.dp)) {
                        OutlinedButton(onClick = { viewModel.setStatus(report.id, "reviewed") }) {
                            Text("Marcar revisada")
                        }
                        OutlinedButton(
                            onClick = { viewModel.setStatus(report.id, "dismissed") },
                            modifier = Modifier.padding(start = 8.dp)
                        ) { Text("Descartar") }
                        OutlinedButton(
                            onClick = { viewModel.banReportedUser(report.id, report.reportedId, report.reason) },
                            colors = androidx.compose.material3.ButtonDefaults.outlinedButtonColors(
                                contentColor = MaterialTheme.colorScheme.error
                            ),
                            modifier = Modifier.padding(start = 8.dp)
                        ) { Text("Banear") }
                    }
                }
                HorizontalDivider()
            }
        }
    }
}
