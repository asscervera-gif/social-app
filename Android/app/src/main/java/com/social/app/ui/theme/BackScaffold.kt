package com.social.app.ui.theme

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * Hallazgo real, sistémico, encontrado por el usuario probando la app de
 * verdad en el emulador ("no se puede volver atrás"): NINGÚN archivo de
 * pantalla en toda la app Android usaba `TopAppBar` -- cada pantalla
 * empujada por navegación (Ajustes, Guardados, Tus publicaciones,
 * Moderación, etc.) dependía ÚNICAMENTE del gesto de "atrás" del sistema,
 * sin ningún botón real en la propia pantalla. En un dispositivo real con
 * gestos táctiles esto ya es un antipatrón de Material Design (Google
 * exige un icono de navegación explícito en pantallas empujadas); en el
 * emulador con ratón, el gesto de borde es casi imposible de repetir,
 * dejando literalmente sin forma de salir. `BackScaffold` centraliza la
 * barra superior real (título + flecha de volver) para no repetir la
 * misma corrección 15 veces de forma inconsistente.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BackScaffold(
    title: String,
    onBack: () -> Unit,
    content: @Composable (androidx.compose.foundation.layout.PaddingValues) -> Unit
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Volver")
                    }
                }
            )
        }
    ) { padding ->
        content(padding)
    }
}
