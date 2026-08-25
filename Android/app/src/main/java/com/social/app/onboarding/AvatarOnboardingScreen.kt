package com.social.app.onboarding

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.social.app.avatar.AvatarLook
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.launch

private enum class Step { CONSENT, PICK_PHOTO, GENERATING, ERROR }

/**
 * Orquesta consentimiento → selfie → "generar avatar" → guardar
 * `avatar_config` — hallazgo real, hueco grande documentado toda la
 * sesión: este flujo nunca existió en Android en absoluto (solo en iOS,
 * ver OnboardingAvatarView.swift). Sigue usando un generador placeholder
 * (color derivado al azar, igual que `PlaceholderAvatarProvider.swift`) —
 * no se inventa aquí una integración real de Avaturn/MetaPerson que no se
 * puede verificar, mismo criterio que el resto de esta sesión.
 */
@Composable
fun AvatarOnboardingScreen(onFinished: () -> Unit) {
    var step by remember { mutableStateOf(Step.CONSENT) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        step = Step.GENERATING
        scope.launch {
            try {
                // La foto original nunca se sube ni se guarda — el
                // "avatar" generado aquí es solo un look elegido de una
                // paleta cerrada (AvatarLook), mismo criterio honesto que
                // PlaceholderAvatarProvider.generateAvatar en iOS. Estilo
                // "busto ilustrado" exacto del boceto SOCIAL_APP.html
                // (ver CartoonAvatar.kt), no un color de degradado suelto.
                val (skin, hair, top) = AvatarLook.random()
                val userId = SupabaseManager.client.auth.currentUserOrNull()?.id
                if (userId != null) {
                    SupabaseManager.client.from("profiles")
                        .update({ set("avatar_config", mapOf("type" to "cartoon", "skin" to skin, "hair" to hair, "top" to top)) }) {
                            filter { eq("id", userId) }
                        }
                }
                onFinished()
            } catch (e: Exception) {
                errorMessage = e.message
                step = Step.ERROR
            }
        }
    }

    when (step) {
        Step.CONSENT -> SelfieConsentScreen(
            onAccept = { step = Step.PICK_PHOTO },
            onDecline = onFinished
        )
        Step.PICK_PHOTO -> Column(modifier = Modifier.fillMaxWidth().padding(28.dp)) {
            Text("Elige una foto de tu cara", style = MaterialTheme.typography.titleMedium)
            Button(
                onClick = { pickImage.launch("image/*") },
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
            ) {
                Text("Elegir foto")
            }
            TextButton(onClick = onFinished) { Text("Ahora no") }
        }
        Step.GENERATING -> Column(modifier = Modifier.fillMaxWidth().padding(28.dp)) {
            CircularProgressIndicator()
            Text("Generando tu avatar…", modifier = Modifier.padding(top = 12.dp))
        }
        Step.ERROR -> Column(modifier = Modifier.fillMaxWidth().padding(28.dp)) {
            Text(
                errorMessage ?: "No se pudo generar el avatar.",
                color = MaterialTheme.colorScheme.error
            )
            Button(onClick = { step = Step.PICK_PHOTO }, modifier = Modifier.padding(top = 12.dp)) {
                Text("Reintentar")
            }
            TextButton(onClick = onFinished) { Text("Ahora no") }
        }
    }
}
