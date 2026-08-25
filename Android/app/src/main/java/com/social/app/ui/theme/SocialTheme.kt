package com.social.app.ui.theme

import android.content.Context
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Hallazgo real, comparado con cualquier app grande (Instagram/Duolingo):
 * no existía NINGÚN sistema de tema compartido -- `MainActivity.kt` tenía
 * un `lightColorScheme(...)` metido a mano e inline, con valores parecidos
 * pero no idénticos a los del logo real, e iOS no tenía NINGÚN color de
 * marca (usaba el azul de sistema por defecto de SwiftUI). Colores
 * extraídos de verdad del asset real (`social_logo.png`, muestreo de
 * píxeles por bucket de tono, no adivinados) -- equivalente exacto de
 * Theme.swift.
 */
object SocialColors {
    // Tinta/texto -- ya usada en MainActivity.kt antes de esta pasada.
    val Ink = Color(0xFF12121A)
    val Background = Color.White
    val SurfaceVariant = Color(0xFFF3F1F7)
    val OnSurfaceVariant = Color(0xFF49454F)
    val ErrorColor = Color(0xFFD32F2F)

    // Hallazgo real, comparado con Instagram/Twitter/WhatsApp/TikTok/
    // Facebook: ninguna de las dos plataformas de esta app tenía modo
    // oscuro en absoluto -- ni siquiera seguía el ajuste del sistema.
    // Mismos tonos base que Material Design recomienda para superficies
    // oscuras (no #000 puro, que "sangra" en pantallas OLED y da menos
    // jerarquía que un gris muy oscuro real).
    val DarkBackground = Color(0xFF121212)
    val DarkSurfaceVariant = Color(0xFF2A2A2E)
    val DarkOnSurfaceVariant = Color(0xFFCAC4CF)
    val DarkInk = Color(0xFFEDEDF2)

    // Los siete acentos reales del arcoíris del wordmark "SOCIAL", uno por
    // letra aproximadamente -- Coral es el que ya se usaba como primary.
    val Coral = Color(0xFFFF5A76)
    val Orange = Color(0xFFFFA630)
    val Gold = Color(0xFFF2B705)
    val Green = Color(0xFF4CAF7D)
    val Turquoise = Color(0xFF29C7C2)
    val Purple = Color(0xFF9B6FE0)
    val Magenta = Color(0xFFF0459B)

    val accents: List<Pair<String, Color>> = listOf(
        "coral" to Coral,
        "orange" to Orange,
        "gold" to Gold,
        "green" to Green,
        "turquoise" to Turquoise,
        "purple" to Purple,
        "magenta" to Magenta
    )

    // Degradado EXACTO del wordmark "SOCIAL"/icono "S" en SOCIAL_APP.html
    // (el boceto que el usuario pidió seguir "exactamente igual"):
    // linear-gradient(90deg,#ff3b3b,#f7b731,#20bf6b,#4dabf7,#a55eea). Fijo
    // -- es identidad de marca, no un acento que el usuario elija en
    // Ajustes (eso sigue siendo `accents`, arriba).
    val WordmarkGradient: List<Color> = listOf(
        Color(0xFFFF3B3B), Color(0xFFF7B731), Color(0xFF20BF6B), Color(0xFF4DABF7), Color(0xFFA55EEA)
    )
}

/**
 * Hallazgo real: no había ninguna forma de personalizar el color de acento
 * -- ver AjustesScreen.kt. Persistido en SharedPreferences (más simple que
 * DataStore para un solo valor, mismo criterio de no traer una dependencia
 * nueva para un caso de uso tan pequeño), expuesto como StateFlow para que
 * SocialTheme recomponga en cuanto cambia, sin reiniciar la app.
 */
object AccentPreference {
    private const val PREFS_NAME = "social_theme_prefs"
    private const val KEY_ACCENT = "accent_color"

    private val _accentKey = MutableStateFlow("coral")
    val accentKey: StateFlow<String> = _accentKey.asStateFlow()

    private var initialized = false

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        _accentKey.value = prefs(context).getString(KEY_ACCENT, "coral") ?: "coral"
    }

    fun setAccent(context: Context, key: String) {
        _accentKey.value = key
        prefs(context).edit().putString(KEY_ACCENT, key).apply()
    }

    fun colorFor(key: String): Color =
        SocialColors.accents.firstOrNull { it.first == key }?.second ?: SocialColors.Coral
}

/**
 * Hallazgo real, comparado con Instagram/Twitter/WhatsApp/TikTok/Facebook:
 * no había ninguna forma de elegir modo oscuro, ni de seguir el ajuste del
 * sistema -- toda la app era clara siempre, sin importar la preferencia
 * real del dispositivo. Mismo patrón exacto que AccentPreference
 * (SharedPreferences + StateFlow, cambia al instante sin reiniciar).
 * "system" (por defecto) sigue `isSystemInDarkTheme()`.
 */
object ThemeModePreference {
    private const val PREFS_NAME = "social_theme_prefs"
    private const val KEY_MODE = "theme_mode"

    private val _mode = MutableStateFlow("system")
    val mode: StateFlow<String> = _mode.asStateFlow()

    private var initialized = false

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        _mode.value = prefs(context).getString(KEY_MODE, "system") ?: "system"
    }

    fun setMode(context: Context, value: String) {
        _mode.value = value
        prefs(context).edit().putString(KEY_MODE, value).apply()
    }
}

@Composable
fun SocialTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    remember { AccentPreference.init(context); ThemeModePreference.init(context); true }
    val accentKey by AccentPreference.accentKey.collectAsState()
    val accent = AccentPreference.colorFor(accentKey)
    val themeMode by ThemeModePreference.mode.collectAsState()
    val isDark = when (themeMode) {
        "dark" -> true
        "light" -> false
        else -> androidx.compose.foundation.isSystemInDarkTheme()
    }

    val colorScheme = if (isDark) {
        androidx.compose.material3.darkColorScheme(
            primary = accent,
            onPrimary = Color.White,
            secondary = SocialColors.Turquoise,
            onSecondary = Color.White,
            tertiary = SocialColors.Orange,
            background = SocialColors.DarkBackground,
            onBackground = SocialColors.DarkInk,
            surface = SocialColors.DarkBackground,
            onSurface = SocialColors.DarkInk,
            surfaceVariant = SocialColors.DarkSurfaceVariant,
            onSurfaceVariant = SocialColors.DarkOnSurfaceVariant,
            error = SocialColors.ErrorColor
        )
    } else {
        lightColorScheme(
            primary = accent,
            onPrimary = Color.White,
            secondary = SocialColors.Turquoise,
            onSecondary = Color.White,
            tertiary = SocialColors.Orange,
            background = SocialColors.Background,
            onBackground = SocialColors.Ink,
            surface = SocialColors.Background,
            onSurface = SocialColors.Ink,
            surfaceVariant = SocialColors.SurfaceVariant,
            onSurfaceVariant = SocialColors.OnSurfaceVariant,
            error = SocialColors.ErrorColor
        )
    }
    MaterialTheme(colorScheme = colorScheme, content = content)
}
