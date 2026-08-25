package com.social.app.auth

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.app.NotificationManagerCompat
import com.social.app.backend.PushTokenManager
import com.social.app.backend.SupabaseManager
import com.social.app.onboarding.AvatarOnboardingScreen
import com.social.app.proximity.SocialProximity
import com.social.app.screens.RootTabView
import io.github.jan.supabase.gotrue.SessionStatus
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Punto de entrada real que faltaba en TODA la sesión: hasta ahora
 * MainActivity mostraba RootTabView siempre, sin comprobar si había una
 * sesión real — cualquiera que abriera la app entraba directo, sin cuenta.
 * Reactivo a `sessionStatus` (no una comprobación puntual): si la sesión
 * expira o se cierra, vuelve a AuthScreen sin tener que matar el proceso.
 */
@Composable
fun AppRoot(proximity: SocialProximity, startTab: String? = null) {
    val sessionStatus by SupabaseManager.client.auth.sessionStatus.collectAsState()
    // Hallazgo real, hueco grande documentado toda la sesión: el
    // onboarding de avatar (SelfieConsentScreen/generateAvatar) nunca
    // existió en Android — se dispara aquí, una vez, cuando el perfil
    // recién autenticado todavía no tiene avatar_config. Mismo patrón que
    // AppRootView.swift/checkNeedsAvatarOnboarding.
    var showAvatarOnboarding by remember { mutableStateOf(false) }
    // Hallazgo real: ninguna plataforma explicaba qué es o cómo funciona
    // la detección UWB antes de soltar al usuario en la cámara —
    // comparado con cualquier app grande (Instagram/TikTok/Snapchat, que
    // sí muestran un carrusel de bienvenida), un hueco real de
    // onboarding. Se muestra una sola vez por dispositivo, la primera
    // vez que hay sesión real. Mismo patrón que showHowItWorks en
    // AppRootView.swift.
    var showHowItWorks by remember { mutableStateOf(false) }
    // Hallazgo real (moderación, 0037_admin_ban.sql): un admin ya podía
    // banear desde ModerationScreen, pero nada del lado del cliente
    // comprobaba nunca si TU PROPIA cuenta estaba baneada — un usuario
    // baneado seguía entrando a la app con normalidad, el baneo solo
    // existía en la base de datos sin ningún efecto real. Se consulta
    // `my_ban_status` (ya resuelve baneos temporales caducados del lado
    // del servidor, no aquí) en cuanto hay sesión.
    var banStatus by remember { mutableStateOf<BanStatusRow?>(null) }
    val context = LocalContext.current
    val coroutineScope = androidx.compose.runtime.rememberCoroutineScope()
    // Equivalente Android de PushTokenManager.requestAuthorizationAndRegister()
    // en iOS. Concedido o no, se registra igual el token FCM abajo -- el
    // permiso solo controla si el sistema muestra la alerta visible, no si
    // FCM entrega el mensaje al servicio (SocialFirebaseMessagingService
    // sigue recibiendo onNewToken/onMessageReceived igual).
    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { PushTokenManager.registerCurrentToken() }

    LaunchedEffect(sessionStatus) {
        // Hallazgo real, mismo criterio ya aplicado en
        // AppRootView.swift: al cerrar sesión, las notificaciones ya
        // entregadas (y el badge del icono que dependía de ellas en los
        // lanzadores que lo soportan) se quedaban con los avisos de la
        // cuenta que se acaba de cerrar — un usuario distinto que inicie
        // sesión en el mismo dispositivo vería avisos ajenos.
        if (sessionStatus is SessionStatus.NotAuthenticated) {
            NotificationManagerCompat.from(context).cancelAll()
        }
        if (sessionStatus is SessionStatus.Authenticated) {
            val userId = SupabaseManager.client.auth.currentUserOrNull()?.id ?: return@LaunchedEffect
            try {
                val row = SupabaseManager.client.from("profiles")
                    .select(columns = Columns.raw("avatar_config")) { filter { eq("id", userId) } }
                    .decodeSingleOrNull<AvatarConfigRow>()
                showAvatarOnboarding = row?.avatarConfig == null
            } catch (e: Exception) {
                // Si falla la comprobación, no se fuerza el onboarding —
                // mejor dejar entrar a la app que bloquear por un error de
                // red puntual.
            }
            showHowItWorks = !hasSeenHowItWorks(context)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                PushTokenManager.registerCurrentToken()
            }
            try {
                banStatus = SupabaseManager.client.from("my_ban_status")
                    .select()
                    .decodeSingleOrNull<BanStatusRow>()
            } catch (e: Exception) {
                // Igual que el onboarding de avatar: un fallo de red al
                // comprobar el baneo no debe bloquear a un usuario legítimo.
                banStatus = null
            }
        }
    }

    when (sessionStatus) {
        is SessionStatus.Authenticated -> {
            if (banStatus?.isCurrentlyBanned == true) {
                BannedScreen(reason = banStatus?.banReason, onSignOut = {
                    coroutineScope.launch { SupabaseManager.client.auth.signOut() }
                })
            } else if (showHowItWorks) {
                HowItWorksScreen(onFinished = { showHowItWorks = false })
            } else {
                RootTabView(proximity, startTab = startTab)
                if (showAvatarOnboarding) {
                    Dialog(onDismissRequest = { showAvatarOnboarding = false }) {
                        AvatarOnboardingScreen(onFinished = { showAvatarOnboarding = false })
                    }
                }
            }
        }
        is SessionStatus.NotAuthenticated -> AuthScreen()
        is SessionStatus.LoadingFromStorage, is SessionStatus.NetworkError -> {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                androidx.compose.foundation.layout.Column(
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    androidx.compose.foundation.Image(
                        painter = androidx.compose.ui.res.painterResource(com.social.app.R.drawable.social_logo),
                        contentDescription = "SOCIAL",
                        contentScale = androidx.compose.ui.layout.ContentScale.Fit,
                        modifier = Modifier.fillMaxWidth(0.5f).height(80.dp)
                    )
                    CircularProgressIndicator(modifier = Modifier.padding(top = 24.dp))
                }
            }
        }
    }
}

@Serializable
private data class AvatarConfigRow(
    @SerialName("avatar_config") val avatarConfig: Map<String, String>? = null
)

@Serializable
private data class BanStatusRow(
    @SerialName("is_currently_banned") val isCurrentlyBanned: Boolean,
    @SerialName("ban_reason") val banReason: String? = null
)

/** Pantalla de bloqueo real cuando `my_ban_status.is_currently_banned` es
 * true — hasta esta pasada, un usuario baneado por un admin en
 * ModerationScreen seguía usando la app con total normalidad, el baneo
 * solo existía como una fila en la base de datos sin ningún efecto. */
@Composable
private fun BannedScreen(reason: String?, onSignOut: () -> Unit) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        androidx.compose.foundation.layout.Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(24.dp)
        ) {
            Text("Cuenta suspendida", style = MaterialTheme.typography.headlineSmall)
            Text(
                reason ?: "Tu cuenta ha sido suspendida por incumplir las normas de la comunidad.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 12.dp, bottom = 24.dp)
            )
            Button(onClick = onSignOut) { Text("Cerrar sesión") }
        }
    }
}
