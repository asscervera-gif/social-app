package com.social.app.auth

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.R
import com.social.app.screens.perfil.PrivacyPolicyScreen
import com.social.app.screens.perfil.TermsOfServiceScreen
import java.time.LocalDate

/**
 * Pantalla de registro/login — no existía en ninguna plataforma, el hueco
 * raíz más grave de toda la sesión (ver AuthViewModel para el detalle
 * completo). Sin campo de foto/avatar aquí a propósito: la generación de
 * avatar (SelfieConsentView/generateAvatar) sigue sin infraestructura real
 * verificada y no se debe fingir aquí — el registro deja un `display_name`
 * real vía `handle_new_user` (0014_handle_new_user.sql) y el avatar por
 * defecto ya es el círculo con gradiente de PlaceholderAvatarProvider.
 */
@Composable
fun AuthScreen(viewModel: AuthViewModel = viewModel()) {
    // Hallazgo real: la app entraba directa al formulario completo de
    // registro al abrir — sin darle a elegir a alguien que YA tiene cuenta
    // la opción de iniciar sesión antes de ver seis campos de un
    // formulario que no le hacen falta. Pantalla de bienvenida real con
    // las dos acciones, como cualquier app de referencia (Instagram,
    // TikTok): null = pantalla de bienvenida, true/false = el formulario
    // ya existente para cada caso.
    var authMode by remember { mutableStateOf<Boolean?>(null) }
    if (authMode == null) {
        WelcomeScreen(
            onSignIn = { authMode = false },
            onCreateAccount = { authMode = true }
        )
        return
    }
    var isSignUp by remember { mutableStateOf(authMode == true) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    var birthDateText by remember { mutableStateOf("") }
    val isLoading by viewModel.isLoading.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val infoMessage by viewModel.infoMessage.collectAsState()
    // Hallazgo real: el registro dejaba crear una cuenta sin aceptar
    // ningún término — no existía ni siquiera el documento de términos de
    // servicio hasta esta pasada (ver legal/terms_of_service_es.md).
    var acceptedTerms by remember { mutableStateOf(false) }
    var showTerms by remember { mutableStateOf(false) }
    var showPrivacy by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp)
    ) {
        TextButton(onClick = { authMode = null }, modifier = Modifier.padding(bottom = 4.dp)) {
            Text("← Volver")
        }
        // Logo real de marca (social_logo.png) en vez del texto "SOCIAL" —
        // centrado con Box + fillMaxWidth, ya que Column por sí solo alinea
        // a la izquierda y el resto del formulario ya usa fillMaxWidth.
        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Image(
                painter = painterResource(R.drawable.social_logo),
                contentDescription = "SOCIAL",
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxWidth(0.7f).height(90.dp)
            )
        }
        Text(
            if (isSignUp) "Crea tu cuenta" else "Inicia sesión",
            style = MaterialTheme.typography.titleMedium,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 20.dp)
        )

        if (isSignUp) {
            OutlinedTextField(
                value = displayName,
                onValueChange = { displayName = it },
                label = { Text("Nombre") },
                modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp)
            )
        }

        OutlinedTextField(
            value = email,
            onValueChange = { email = it },
            label = { Text("Email") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
            modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp)
        )

        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = { Text("Contraseña") },
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp)
        )

        if (isSignUp) {
            OutlinedTextField(
                value = birthDateText,
                onValueChange = { birthDateText = it },
                label = { Text("Fecha de nacimiento (AAAA-MM-DD)") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp)
            )
            Text(
                "SOCIAL es solo para mayores de 18 años.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 12.dp)
            )
            // Hallazgo real: con verticalAlignment = CenterVertically, el
            // checkbox se centraba respecto al BLOQUE ENTERO (las dos líneas:
            // el texto "Acepto los términos..." + la fila de enlaces debajo),
            // así que quedaba desplazado hacia abajo y no alineado con la
            // primera línea que es la que de verdad describe lo que marca.
            Row(verticalAlignment = Alignment.Top, modifier = Modifier.padding(bottom = 12.dp)) {
                Checkbox(
                    checked = acceptedTerms,
                    onCheckedChange = { acceptedTerms = it },
                    modifier = Modifier.padding(top = 0.dp)
                )
                Column(modifier = Modifier.padding(top = 12.dp)) {
                    Text("Acepto los términos y la política de privacidad", style = MaterialTheme.typography.bodySmall)
                    Row {
                        TextButton(onClick = { showTerms = true }) { Text("Ver términos", style = MaterialTheme.typography.bodySmall) }
                        TextButton(onClick = { showPrivacy = true }) { Text("Ver privacidad", style = MaterialTheme.typography.bodySmall) }
                    }
                }
            }
        }

        errorMessage?.let {
            Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(bottom = 12.dp))
        }
        infoMessage?.let {
            Text(it, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(bottom = 12.dp))
        }

        Button(
            onClick = {
                if (isSignUp) {
                    val birthDate = try {
                        LocalDate.parse(birthDateText)
                    } catch (e: Exception) {
                        null
                    }
                    if (birthDate == null) {
                        // Fecha ilegible: no se llama a signUp con una fecha
                        // inventada — LocalDate.now() daría edad 0 y
                        // bloquearía con un mensaje confuso ("menor de 18")
                        // en vez de pedir corregir el formato.
                        viewModel.reportInvalidBirthDate()
                    } else {
                        viewModel.signUp(email, password, displayName, birthDate)
                    }
                } else {
                    viewModel.signIn(email, password)
                }
            },
            enabled = !isLoading && email.isNotBlank() && password.isNotBlank() && (!isSignUp || acceptedTerms),
            modifier = Modifier.fillMaxWidth()
        ) {
            if (isLoading) CircularProgressIndicator(modifier = Modifier.padding(end = 8.dp))
            Text(if (isSignUp) "Crear cuenta" else "Entrar")
        }

        TextButton(onClick = { isSignUp = !isSignUp }, modifier = Modifier.padding(top = 8.dp)) {
            Text(if (isSignUp) "¿Ya tienes cuenta? Inicia sesión" else "¿No tienes cuenta? Regístrate")
        }

        if (!isSignUp) {
            // Hallazgo real: no había ningún flujo de recuperación de
            // contraseña — un usuario que la olvida se quedaría bloqueado
            // para siempre.
            TextButton(onClick = { viewModel.resetPassword(email) }) {
                Text("¿Olvidaste tu contraseña?")
            }
        }
    }

    if (showTerms) {
        AlertDialog(
            onDismissRequest = { showTerms = false },
            confirmButton = { TextButton(onClick = { showTerms = false }) { Text("Cerrar") } },
            text = { TermsOfServiceScreen() }
        )
    }
    if (showPrivacy) {
        AlertDialog(
            onDismissRequest = { showPrivacy = false },
            confirmButton = { TextButton(onClick = { showPrivacy = false }) { Text("Cerrar") } },
            text = { PrivacyPolicyScreen() }
        )
    }
}

@Composable
private fun WelcomeScreen(onSignIn: () -> Unit, onCreateAccount: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Image(
            painter = painterResource(R.drawable.social_logo),
            contentDescription = "SOCIAL",
            contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxWidth(0.85f).height(120.dp)
        )
        Text(
            "Descubre a la gente que tienes cerca de verdad",
            style = MaterialTheme.typography.titleMedium,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.padding(top = 16.dp, bottom = 48.dp)
        )
        Button(onClick = onCreateAccount, modifier = Modifier.fillMaxWidth()) {
            Text("Crear cuenta")
        }
        TextButton(onClick = onSignIn, modifier = Modifier.padding(top = 12.dp)) {
            Text("Ya tengo cuenta — Iniciar sesión")
        }
    }
}
