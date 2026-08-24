package com.social.app.screens.perfil

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * Hallazgo real, legalmente relevante: `legal/privacy_policy_es.md` existe
 * en el repositorio (el documento que ya se auditó y corrigió varias
 * veces esta sesión) pero nunca se mostraba DENTRO de la app — ni desde
 * Ajustes ni desde el registro. App Store/Play Store exigen que la
 * política de privacidad sea accesible desde la propia app, no solo un
 * archivo en el repositorio. Copiado a `assets/` (mismo contenido, texto
 * plano — sin renderer de Markdown, dependencia nueva innecesaria solo
 * para esto). Nota de mantenimiento: si se edita el .md original en
 * `legal/`, hay que volver a copiarlo aquí; no se lee en vivo del
 * repositorio porque la app compilada no tiene acceso a él.
 */
@Composable
fun PrivacyPolicyScreen() {
    LegalDocScreen(assetName = "privacy_policy_es.md", fallback = "No se pudo cargar la política de privacidad.")
}

/** Términos de servicio — mismo hallazgo, hueco real: no existía ni
 * siquiera el documento en `legal/` hasta esta pasada, y el registro
 * dejaba crear una cuenta sin aceptar ningún término (ver AuthScreen.kt). */
@Composable
fun TermsOfServiceScreen() {
    LegalDocScreen(assetName = "terms_of_service_es.md", fallback = "No se pudieron cargar los términos de servicio.")
}

@Composable
private fun LegalDocScreen(assetName: String, fallback: String) {
    val context = LocalContext.current
    var text by remember { mutableStateOf("Cargando…") }

    LaunchedEffect(assetName) {
        text = try {
            context.assets.open(assetName).bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            fallback
        }
    }

    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)
    )
}
