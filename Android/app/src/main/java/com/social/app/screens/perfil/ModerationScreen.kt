package com.social.app.screens.perfil

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.draw.clip
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
data class AppealEntry(
    val id: String,
    @SerialName("profile_id") val profileId: String,
    val message: String,
    val status: String,
    @SerialName("created_at") val createdAt: String,
    val profileName: String? = null
)

@Serializable
data class ReportEntry(
    val id: String,
    @SerialName("reporter_id") val reporterId: String,
    @SerialName("reported_id") val reportedId: String,
    val reason: String,
    val details: String? = null,
    val status: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("post_id") val postId: String? = null,
    @SerialName("comment_id") val commentId: String? = null,
    // Hallazgo real, comparado con Instagram/WhatsApp/Messenger: mismo
    // hueco exacto que post_id/comment_id pero en un chat --
    // 0048_reports_message_reference.sql.
    @SerialName("message_id") val messageId: String? = null,
    val reporterName: String? = null,
    val reportedName: String? = null,
    // Hallazgo real, comparado con Instagram/TikTok/Facebook: antes un
    // admin solo veía un texto libre editable ("Publicación {id}") sin
    // forma real de ver el contenido -- ahora se resuelve el post/
    // comentario real referenciado (0045_reports_content_reference.sql).
    val postCaption: String? = null,
    val postMediaUrl: String? = null,
    val commentBody: String? = null,
    val messageBody: String? = null,
    val messageMediaUrl: String? = null
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

    // Hallazgo real, comparado con Instagram/TikTok/Facebook, segunda
    // mitad de 0043_ban_appeals.sql: hasta esta pasada un usuario baneado
    // no tenía ninguna forma de apelar, y aunque la tuviera, ningún admin
    // podía revisarlas -- mismo patrón que reports, cola aparte porque es
    // un concepto distinto (una apelación siempre implica desbanear o no,
    // una denuncia no).
    private val _appeals = MutableStateFlow<List<AppealEntry>>(emptyList())
    val appeals: StateFlow<List<AppealEntry>> = _appeals.asStateFlow()

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

    @Serializable
    private data class PostContentRow(val caption: String? = null, @SerialName("media_url") val mediaUrl: String? = null)

    @Serializable
    private data class CommentContentRow(val body: String)

    @Serializable
    private data class MessageContentRow(val body: String? = null, @SerialName("media_url") val mediaUrl: String? = null)

    /** Resuelve el contenido real denunciado -- si el post/comentario ya
     * se borró (0045: `on delete set null`), simplemente no hay nada que
     * mostrar, la denuncia en sí sigue existiendo para el historial. */
    private suspend fun resolveContent(entry: ReportEntry): ReportEntry {
        val post = entry.postId?.let { postId ->
            try {
                SupabaseManager.client.from("posts")
                    .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("caption,media_url")) {
                        filter { eq("id", postId) }
                    }
                    .decodeSingleOrNull<PostContentRow>()
            } catch (e: Exception) {
                null
            }
        }
        val comment = entry.commentId?.let { commentId ->
            try {
                SupabaseManager.client.from("comments")
                    .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("body")) {
                        filter { eq("id", commentId) }
                    }
                    .decodeSingleOrNull<CommentContentRow>()
            } catch (e: Exception) {
                null
            }
        }
        // messages_select_admin (0048) solo deja ver mensajes que SÍ están
        // referenciados por una denuncia real -- a diferencia de
        // posts_select_admin/comments_select_admin (0045), no es un bypass
        // general para cualquier admin: un chat es la superficie más
        // privada de la app, y aquí el criterio es más conservador a
        // propósito.
        val message = entry.messageId?.let { messageId ->
            try {
                SupabaseManager.client.from("messages")
                    .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("body,media_url")) {
                        filter { eq("id", messageId) }
                    }
                    .decodeSingleOrNull<MessageContentRow>()
            } catch (e: Exception) {
                null
            }
        }
        return entry.copy(
            postCaption = post?.caption, postMediaUrl = post?.mediaUrl, commentBody = comment?.body,
            messageBody = message?.body, messageMediaUrl = message?.mediaUrl
        )
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
                    resolveContent(
                        entry.copy(
                            reporterName = nameFor(entry.reporterId),
                            reportedName = nameFor(entry.reportedId)
                        )
                    )
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar las denuncias."
            }
            loadAppeals()
        }
    }

    private suspend fun loadAppeals() {
        try {
            // ban_appeals_select_admin (0043) devuelve cero filas si quien
            // llama no es admin real -- mismo criterio que reports.
            val rows = SupabaseManager.client.from("ban_appeals")
                .select {
                    filter { eq("status", "open") }
                    order("created_at", Order.DESCENDING)
                    limit(100)
                }
                .decodeList<AppealEntry>()
            _appeals.value = rows.map { it.copy(profileName = nameFor(it.profileId)) }
        } catch (e: Exception) {
            _errorMessage.value = "No se pudieron cargar las apelaciones."
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

    private fun setAppealStatus(appealId: String, status: String) {
        _appeals.value = _appeals.value.filter { it.id != appealId }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("ban_appeals")
                    .update({ set("status", status) }) { filter { eq("id", appealId) } }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo actualizar la apelación."
                loadAppeals()
            }
        }
    }

    /** "Aceptar apelación": desbanea de verdad (mismo `admin_ban_user` que
     * ya usa `banReportedUser`, con `p_banned = false`) y marca la
     * apelación como revisada -- una apelación aceptada siempre implica
     * desbanear, no tiene sentido separarlo en dos pasos manuales. */
    fun acceptAppeal(appealId: String, profileId: String) {
        viewModelScope.launch {
            try {
                SupabaseManager.client.postgrest.rpc(
                    "admin_ban_user",
                    BanParams(targetId = profileId, banned = false)
                )
                com.social.app.backend.AnalyticsManager.track("appeal_accepted")
                setAppealStatus(appealId, "reviewed")
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo desbanear a este usuario."
            }
        }
    }

    fun dismissAppeal(appealId: String) {
        setAppealStatus(appealId, "dismissed")
    }
}

@Composable
fun ModerationScreen(viewModel: ModerationViewModel = viewModel()) {
    val reports by viewModel.reports.collectAsState()
    val appeals by viewModel.appeals.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Moderación", style = MaterialTheme.typography.headlineSmall)
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }

        // Hallazgo real, comparado con Instagram/TikTok/Facebook: hasta
        // esta pasada un usuario baneado no tenía ninguna forma de
        // apelar, y aunque la tuviera, ningún admin podía revisarlas.
        if (appeals.isNotEmpty()) {
            Text("Apelaciones de baneo", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 16.dp))
            LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp).heightIn(max = 260.dp)) {
                items(appeals, key = { it.id }) { appeal ->
                    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                        Text(appeal.profileName ?: "Perfil", style = MaterialTheme.typography.labelMedium)
                        Text(appeal.message, style = MaterialTheme.typography.bodySmall)
                        Row(modifier = Modifier.fillMaxWidth().padding(top = 6.dp)) {
                            OutlinedButton(onClick = { viewModel.acceptAppeal(appeal.id, appeal.profileId) }) {
                                Text("Desbanear")
                            }
                            OutlinedButton(
                                onClick = { viewModel.dismissAppeal(appeal.id) },
                                modifier = Modifier.padding(start = 8.dp)
                            ) { Text("Descartar") }
                        }
                    }
                    HorizontalDivider()
                }
            }
        }

        Text("Denuncias", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 16.dp))
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
                    // Hallazgo real, comparado con Instagram/TikTok/
                    // Facebook: antes, si la denuncia era sobre un post o
                    // un comentario concreto, no había forma real de
                    // verlo -- solo un texto libre editable por el
                    // denunciante. Ahora se muestra el contenido real
                    // (0045_reports_content_reference.sql), o un aviso
                    // honesto si ya se borró.
                    if (report.postId != null) {
                        Column(modifier = Modifier.padding(top = 6.dp)) {
                            Text("Publicación denunciada:", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            report.postMediaUrl?.let { url ->
                                androidx.compose.foundation.Image(
                                    painter = coil.compose.rememberAsyncImagePainter(url),
                                    contentDescription = null,
                                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                    modifier = Modifier.fillMaxWidth().heightIn(max = 160.dp)
                                        .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                                )
                            }
                            Text(report.postCaption ?: "(la publicación ya no existe)", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    if (report.commentId != null) {
                        Column(modifier = Modifier.padding(top = 6.dp)) {
                            Text("Comentario denunciado:", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(report.commentBody ?: "(el comentario ya no existe)", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    // Hallazgo real, comparado con Instagram/WhatsApp/
                    // Messenger: mismo hueco exacto que post/comentario
                    // pero en un chat -- 0048_reports_message_reference.sql.
                    if (report.messageId != null) {
                        Column(modifier = Modifier.padding(top = 6.dp)) {
                            Text("Mensaje denunciado:", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            report.messageMediaUrl?.let { url ->
                                androidx.compose.foundation.Image(
                                    painter = coil.compose.rememberAsyncImagePainter(url),
                                    contentDescription = null,
                                    contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                                    modifier = Modifier.fillMaxWidth().heightIn(max = 160.dp)
                                        .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
                                )
                            }
                            Text(report.messageBody ?: "(el mensaje ya no existe)", style = MaterialTheme.typography.bodySmall)
                        }
                    }
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
