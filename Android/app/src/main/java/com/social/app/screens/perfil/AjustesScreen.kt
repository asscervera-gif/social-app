package com.social.app.screens.perfil

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
private data class IsAdminRow(@SerialName("is_admin") val isAdmin: Boolean)

/** Categorías visibles en Ajustes -> valores reales de `notifications.kind`
 * que agrupa cada una -- mismos valores exactos que
 * AvisosViewModel.kt.icon()/title() y send-push/index.ts. */
// Hallazgo real (0058_group_message_notify.sql): "comment_like"/
// "reel_comment_like" (0054_comment_likes.sql, varias rondas atrás) nunca
// se añadieron a ninguna categoría -- silenciar "Me gusta" no silenciaba
// en realidad el like a un comentario, solo el like a la publicación
// entera. "group_message" (0057_group_chats.sql) añadido a "Mensajes".
// "mention" (0074_mentions.sql) en su propia categoría -- comparado con
// Instagram, que también deja silenciar menciones por separado de
// comentarios normales (una mención puede llegar de alguien que no te
// esté comentando nada a ti directamente).
private val NOTIFICATION_CATEGORIES: List<Pair<String, List<String>>> = listOf(
    "Mensajes" to listOf("message", "group_message"),
    "Me gusta" to listOf("like", "reel_like", "comment_like", "reel_comment_like"),
    "Comentarios" to listOf("comment", "reel_comment"),
    "Menciones" to listOf("mention"),
    "Socials" to listOf("social", "social_accepted"),
    "Seguidores" to listOf("follow"),
    "Duelos" to listOf("fight"),
    "Compatibilidad" to listOf("compat_request", "compat_accepted")
)

/**
 * Pantalla de Ajustes — antes no existía ninguna en absoluto, en ninguna
 * plataforma, a pesar de que `privacy_policy_es.md` ya prometía "borrado
 * completo de tu perfil... desde Ajustes". Confirmación de dos pasos antes
 * de un borrado irreversible.
 */
@Composable
fun AjustesScreen(
    onAccountDeleted: () -> Unit,
    onOpenBlockedUsers: () -> Unit,
    onOpenRestrictedUsers: () -> Unit = {},
    onOpenCompatShares: () -> Unit = {},
    onOpenPrivacyPolicy: () -> Unit = {},
    onOpenModeration: () -> Unit = {},
    // "Mejores amigos" real para historias (0075_close_friends_stories.sql),
    // comparado con Instagram/Snapchat.
    onOpenCloseFriends: () -> Unit = {}
) {
    val context = LocalContext.current
    val account = remember { AccountManager() }
    val isDeleting by account.isDeleting.collectAsState()
    val errorMessage by account.errorMessage.collectAsState()
    var showConfirm by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // Hallazgo real: `compat_public`/`location_public` se consultaban en
    // Match/Home/"Find" pero no había ningún interruptor para activarlos
    // en ninguna plataforma — se quedaban en `false` para siempre (ver
    // PrivacySettingsViewModel.kt).
    val privacy = remember { PrivacySettingsViewModel() }
    val compatPublic by privacy.compatPublic.collectAsState()
    val locationPublic by privacy.locationPublic.collectAsState()
    val readReceiptsEnabled by privacy.readReceiptsEnabled.collectAsState()
    LaunchedEffect(Unit) { privacy.load() }

    // Hallazgo real: `reports` existía y ya recibía denuncias reales
    // desde hace muchas pasadas, pero nadie podía leerlas nunca sin una
    // clave privilegiada — `is_admin` (0036_admin_moderation.sql) es una
    // columna protegida por trigger, igual que `is_verified`, nunca
    // autoconcedible por el cliente. Este botón solo aparece si la
    // consulta real a `profiles` (RLS ya limita a leer la propia fila
    // como cualquier otra) confirma `is_admin = true`.
    var isAdmin by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@LaunchedEffect
        try {
            isAdmin = SupabaseManager.client.from("profiles")
                .select(columns = io.github.jan.supabase.postgrest.query.Columns.raw("is_admin")) {
                    filter { eq("id", userId) }
                }
                .decodeSingleOrNull<IsAdminRow>()?.isAdmin ?: false
        } catch (e: Exception) {
            isAdmin = false
        }
    }

    // Hallazgo real: había recuperación de contraseña por email (pasada
    // anterior) pero ninguna forma de cambiarla estando ya dentro de la
    // cuenta.
    val changePassword = remember { ChangePasswordViewModel() }
    val isSavingPassword by changePassword.isSaving.collectAsState()
    val passwordError by changePassword.errorMessage.collectAsState()
    val passwordSuccess by changePassword.successMessage.collectAsState()
    var newPassword by remember { mutableStateOf("") }

    // Verificación real (insignia azul, 0080_verification_requests.sql),
    // comparado con Instagram/Twitter/TikTok.
    val verification = remember { VerificationRequestViewModel() }
    val isVerified by verification.isVerified.collectAsState()
    val hasOpenVerificationRequest by verification.hasOpenRequest.collectAsState()
    val verificationError by verification.errorMessage.collectAsState()
    val verificationSuccess by verification.successMessage.collectAsState()
    var verificationMessage by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { verification.load() }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Ajustes", style = MaterialTheme.typography.headlineSmall)

        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }

        // Hallazgo real, comparado con cualquier app grande: no había
        // ninguna forma de personalizar el color de acento -- solo el
        // coral por defecto, metido a mano. Los siete colores son los
        // reales del arcoíris del wordmark del logo (ver SocialColors),
        // no inventados. Cambia al instante, sin reiniciar la app (ver
        // AccentPreference, StateFlow observado por SocialTheme).
        Text("Apariencia", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
        val accentKey by com.social.app.ui.theme.AccentPreference.accentKey.collectAsState()
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            com.social.app.ui.theme.SocialColors.accents.forEach { (key, color) ->
                val selected = key == accentKey
                androidx.compose.foundation.layout.Box(
                    modifier = Modifier
                        .size(if (selected) 40.dp else 32.dp)
                        .clip(CircleShape)
                        .background(color)
                        .then(
                            if (selected) Modifier.border(2.dp, MaterialTheme.colorScheme.onSurface, CircleShape)
                            else Modifier
                        )
                        .clickable { com.social.app.ui.theme.AccentPreference.setAccent(context, key) }
                )
            }
        }

        // Hallazgo real, comparado con Instagram/Twitter/WhatsApp/TikTok/
        // Facebook: no había modo oscuro en absoluto, ni forma de seguir
        // el ajuste del sistema -- toda la app era clara siempre. Mismo
        // patrón exacto que el selector de acento de arriba.
        Text("Tema", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp))
        val themeMode by com.social.app.ui.theme.ThemeModePreference.mode.collectAsState()
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            listOf("system" to "Sistema", "light" to "Claro", "dark" to "Oscuro").forEach { (key, label) ->
                val selected = themeMode == key
                Text(
                    label,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .clip(RoundedCornerShape(14.dp))
                        .background(if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant)
                        .clickable { com.social.app.ui.theme.ThemeModePreference.setMode(context, key) }
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                )
            }
        }

        // Hallazgo real, comparado con Instagram/Twitter/Facebook/WhatsApp:
        // todas dejan silenciar "me gusta" sin silenciar "mensajes" -- esta
        // app solo tenía silenciar un CHAT completo, nunca una CATEGORÍA de
        // aviso. Se aplica de verdad en el servidor (send-push/index.ts,
        // 0052_notification_prefs.sql), no solo en el cliente.
        Text("Notificaciones", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp))
        val mutedKinds by privacy.mutedKinds.collectAsState()
        NOTIFICATION_CATEGORIES.forEach { (label, kinds) ->
            val muted = kinds.any { it in mutedKinds }
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(label)
                Switch(checked = !muted, onCheckedChange = { enabled -> privacy.setCategoryMuted(kinds, !enabled) })
            }
        }

        // Verificación real (insignia azul, 0080_verification_requests.sql),
        // comparado con Instagram/Twitter/TikTok -- las tres dejan
        // SOLICITAR la verificación; un equipo revisa y aprueba o
        // rechaza. `is_verified` ya se pintaba de verdad en varias
        // pantallas, pero no existía ningún camino real para llegar a
        // `true` salvo escribirlo a mano en la base de datos.
        Text("Verificación", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp))
        verificationError?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 4.dp)) }
        verificationSuccess?.let { Text(it, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 4.dp)) }
        when {
            isVerified -> Text(
                "Tu cuenta ya está verificada ✔️",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp)
            )
            hasOpenVerificationRequest -> Text(
                "Tienes una solicitud de verificación pendiente de revisión.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp)
            )
            else -> Column(modifier = Modifier.padding(top = 8.dp)) {
                OutlinedTextField(
                    value = verificationMessage,
                    onValueChange = { verificationMessage = it },
                    label = { Text("¿Por qué debería verificarse tu cuenta?") },
                    modifier = Modifier.fillMaxWidth()
                )
                Button(
                    onClick = { verification.submitRequest(verificationMessage) },
                    enabled = verificationMessage.isNotBlank(),
                    modifier = Modifier.padding(top = 8.dp)
                ) { Text("Solicitar verificación") }
            }
        }

        // Palabras silenciadas reales en comentarios
        // (0078_muted_keywords.sql), comparado con Instagram/Twitter --
        // oculta automáticamente cualquier comentario propio (post o
        // reel) que contenga una de estas palabras, sin bloquear a
        // nadie: el comentario sigue existiendo de verdad para todos los
        // demás, incluido quien lo escribió.
        Text("Palabras silenciadas", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp))
        Text(
            "Oculta comentarios que contengan estas palabras, solo para ti.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        val mutedKeywords by privacy.mutedKeywords.collectAsState()
        var newKeyword by remember { mutableStateOf("") }
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = newKeyword,
                onValueChange = { newKeyword = it },
                placeholder = { Text("nueva palabra") },
                singleLine = true,
                modifier = Modifier.weight(1f)
            )
            Button(
                onClick = { privacy.addMutedKeyword(newKeyword); newKeyword = "" },
                enabled = newKeyword.isNotBlank(),
                modifier = Modifier.padding(start = 8.dp)
            ) { Text("Añadir") }
        }
        mutedKeywords.forEach { word ->
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(word)
                androidx.compose.material3.TextButton(onClick = { privacy.removeMutedKeyword(word) }) { Text("Quitar") }
            }
        }

        Text("Privacidad", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp))
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.padding(end = 12.dp)) {
                Text("Compatibilidad pública")
                Text(
                    "Deja que cualquiera vea tu % de compatibilidad sin tener que pedirlo",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(checked = compatPublic, onCheckedChange = { privacy.setCompatPublic(it) })
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.padding(end = 12.dp)) {
                Text("Ubicación pública")
                Text(
                    "Muestra tu ubicación en el mapa de \"Find\"",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(checked = locationPublic, onCheckedChange = { privacy.setLocationPublic(context, it) })
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.padding(end = 12.dp)) {
                // Recibo de lectura real ("Leído ✓✓"), comparado con
                // WhatsApp/Instagram/Messenger -- criterio recíproco real:
                // si lo apagas, tampoco ves el de los demás (ver
                // ChatViewModel.kt.opponentReadReceiptsEnabled, 0091).
                Text("Recibos de lectura")
                Text(
                    "Muestra \"Leído ✓✓\" a los demás. Si lo apagas, tampoco verás el suyo.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(checked = readReceiptsEnabled, onCheckedChange = { privacy.setReadReceiptsEnabled(it) })
        }

        // Hallazgo real: mismo patrón que socials — una vez aceptada una
        // compat_request, no había NINGUNA forma de revocar el acceso a
        // tu % de compatibilidad (ver CompatSharesViewModel.kt).
        OutlinedButton(
            onClick = onOpenCompatShares,
            modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
        ) {
            Text("Quién ve tu compatibilidad")
        }

        // Hallazgo real: bloquear era permanente — SafetyManager.block()
        // existía pero no había forma de ver ni deshacer un bloqueo (ver
        // BlockedUsersViewModel/Screen).
        OutlinedButton(
            onClick = onOpenBlockedUsers,
            modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
        ) {
            Text("Usuarios bloqueados")
        }

        // Restringir una cuenta real, comparado con Instagram --
        // deliberadamente más suave que bloquear (arriba): sus
        // comentarios dejan de verse para los demás sin que se entere de
        // nada. Ver SafetyManager.restrict()/ReportSheet.kt,
        // RestrictedUsersViewModel/Screen, 0093_restrict_account.sql.
        OutlinedButton(
            onClick = onOpenRestrictedUsers,
            modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
        ) {
            Text("Cuentas restringidas")
        }

        // Hallazgo real de seguridad, comparado con Instagram/Snapchat:
        // `stories_select` no tenía NINGUNA restricción de audiencia --
        // cualquiera veía la historia de cualquiera. Ver
        // CloseFriendsViewModel.kt.
        OutlinedButton(
            onClick = onOpenCloseFriends,
            modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
        ) {
            Text("Mejores amigos")
        }

        if (isAdmin) {
            OutlinedButton(
                onClick = onOpenModeration,
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
            ) {
                Text("Moderación")
            }
        }

        // Entrada de prueba temporal para verificar en ejecución el motor
        // de avatares 3D real (SceneView/Filament + Quaternius Universal
        // Base Characters, CC0) — no es la integración final (esa va en
        // la pestaña Avatar del perfil rediseñado), solo el punto más
        // rápido para confirmar que carga un modelo 3D real en pantalla.
        var showAvatar3D by remember { mutableStateOf(false) }
        OutlinedButton(
            onClick = { showAvatar3D = true },
            modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
        ) {
            Text("🧪 Ver avatar 3D (prueba)")
        }
        if (showAvatar3D) {
            // Hallazgo real: dentro de un Dialog (ventana Android separada)
            // el visor renderizaba negro puro pese a cargar el modelo sin
            // error — SurfaceView/Filament tiene problemas conocidos de
            // composición dentro de ventanas de diálogo. Renderizado
            // inline (sin Dialog) para aislar si esa es la causa real.
            androidx.compose.foundation.layout.Box(
                modifier = Modifier.fillMaxWidth().height(400.dp).padding(top = 8.dp)
            ) {
                com.social.app.avatar3d.Avatar3DViewer(modifier = Modifier.fillMaxWidth().height(400.dp))
            }
        }

        Text("Cuenta", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 20.dp))
        OutlinedTextField(
            value = newPassword,
            onValueChange = { newPassword = it },
            label = { Text("Nueva contraseña") },
            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp)
        )
        passwordError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        passwordSuccess?.let { Text(it, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodySmall) }
        OutlinedButton(
            onClick = { changePassword.changePassword(newPassword) },
            enabled = !isSavingPassword,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp)
        ) {
            if (isSavingPassword) CircularProgressIndicator(modifier = Modifier.padding(end = 8.dp))
            Text("Cambiar contraseña")
        }

        // Hallazgo real: antes no había pantalla de login a la que volver,
        // así que ni siquiera tenía sentido un botón de cerrar sesión — ya
        // sí, con AuthScreen.kt/AppRoot.kt reaccionando a sessionStatus.
        OutlinedButton(
            onClick = { scope.launch { SupabaseManager.client.auth.signOut() } },
            modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
        ) {
            Text("Cerrar sesión")
        }

        // Hallazgo real, legalmente relevante: la política de privacidad
        // existía como documento del repositorio pero nunca se mostraba
        // dentro de la app (ver PrivacyPolicyScreen.kt).
        OutlinedButton(
            onClick = onOpenPrivacyPolicy,
            modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
        ) {
            Text("Política de privacidad")
        }

        OutlinedButton(
            onClick = { showConfirm = true },
            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            modifier = Modifier.fillMaxWidth().padding(top = 24.dp)
        ) {
            if (isDeleting) CircularProgressIndicator(modifier = Modifier.padding(end = 8.dp))
            Text("Borrar mi cuenta")
        }
    }

    if (showConfirm) {
        AlertDialog(
            onDismissRequest = { showConfirm = false },
            title = { Text("¿Borrar tu cuenta?") },
            text = { Text("Esto borra tu perfil, publicaciones, mensajes, socials y todos los datos asociados de forma permanente. No se puede deshacer.") },
            confirmButton = {
                Button(onClick = {
                    showConfirm = false
                    scope.launch {
                        if (account.deleteAccount()) onAccountDeleted()
                    }
                }) { Text("Borrar de verdad") }
            },
            dismissButton = {
                OutlinedButton(onClick = { showConfirm = false }) { Text("Cancelar") }
            }
        )
    }
}
