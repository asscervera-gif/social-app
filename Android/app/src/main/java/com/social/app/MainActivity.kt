package com.social.app

import android.Manifest
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import com.social.app.auth.AppRoot
import com.social.app.backend.AnalyticsManager
import com.social.app.backend.SupabaseManager
import com.social.app.proximity.SocialProximity

/**
 * Punto de entrada de SOCIAL para Android. Igual que en iOS, la pantalla
 * inicial es la cámara de proximidad, no un feed — mismo principio de
 * producto en ambas plataformas. La pantalla de cámara en sí vive en
 * camera/SocialCameraScreen.kt (CameraX + marcadores UWB reales).
 */
class MainActivity : ComponentActivity() {

    private lateinit var proximity: SocialProximity

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        if (results.values.all { it }) {
            proximity.start()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SupabaseManager.initialize(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY)
        AnalyticsManager.track("app_open")
        proximity = SocialProximity(applicationContext)

        val permissions = mutableListOf(
            Manifest.permission.CAMERA,
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.UWB_RANGING
        )
        // Obligatorio en Android 13+ (API 33) para las estrategias Wi-Fi de
        // Nearby Connections — encontrado revisando logcat en el emulador
        // ("MISSING_PERMISSION_NEARBY_WIFI_DEVICES"), no estaba ni declarado
        // en el manifest ni solicitado en tiempo de ejecución.
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            permissions.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        permissionLauncher.launch(permissions.toTypedArray())

        setContent {
            // Hallazgo real: `MaterialTheme { }` sin esquema explícito sigue
            // el tema oscuro del sistema — en un emulador/teléfono con modo
            // oscuro activado (el caso normal hoy en día), toda la app se
            // veía negra pese a no haber diseñado nunca una versión oscura
            // real. Esquema claro fijo, fondo blanco, con los colores reales
            // del logo (social_logo.png: coral/rosa y turquesa del arcoíris
            // del wordmark) en vez de los morados por defecto de Compose.
            val socialColorScheme = lightColorScheme(
                primary = Color(0xFFFF5A76),      // rosa/coral del logo
                onPrimary = Color.White,
                secondary = Color(0xFF29C7C2),    // turquesa del logo
                onSecondary = Color.White,
                tertiary = Color(0xFFFFA630),     // naranja del logo
                background = Color.White,
                onBackground = Color(0xFF12121A),
                surface = Color.White,
                onSurface = Color(0xFF12121A),
                surfaceVariant = Color(0xFFF3F1F7),
                onSurfaceVariant = Color(0xFF49454F),
                error = Color(0xFFD32F2F)
            )
            MaterialTheme(colorScheme = socialColorScheme) {
                // Hallazgo real más grave de la sesión: antes se mostraba
                // RootTabView siempre, sin comprobar sesión — ver
                // AppRoot.kt/AuthScreen.kt.
                AppRoot(proximity)
            }
        }
    }

    override fun onDestroy() {
        proximity.stop()
        super.onDestroy()
    }
}
