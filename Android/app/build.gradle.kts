import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

// Push real (FCM): el plugin google-services genera configuración a partir
// de google-services.json y ROMPE EL BUILD ENTERO si el archivo no existe
// -- aplicado solo condicionalmente para no romper compilaciones locales/CI
// existentes hasta que exista un proyecto Firebase real (mismo criterio que
// Config.plist/local.properties: credencial real, no versionada, pendiente
// de que el usuario cree el proyecto en console.firebase.google.com).
// Sin el plugin aplicado, FirebaseMessagingService sigue compilando (la
// librería no necesita el plugin en tiempo de compilación), simplemente
// FirebaseApp no se autoinicializa en tiempo de ejecución -- comportamiento
// documentado y seguro de FirebaseInitProvider, no un crash.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Credenciales de Supabase leídas de local.properties (no versionado, igual
// que Config.plist en iOS) — ver comentario en SupabaseManager.kt.
val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) load(file.inputStream())
}

android {
    namespace = "com.social.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.social.app"
        // minSdk 26 (Android 8), NO 31: la app entera no debe excluir a nadie
        // por debajo de Android 12 solo porque UWB lo requiera. SocialProximity
        // comprueba Build.VERSION.SDK_INT en tiempo de ejecución y degrada con
        // un mensaje claro en dispositivos <31 o sin chip UWB — el resto de la
        // app (perfil, chat, feed, duelos) funciona igual sin proximidad física.
        // Requiere `tools:overrideLibrary` en AndroidManifest.xml porque
        // androidx.core.uwb declara minSdk 31 en su propio manifest.
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"

        buildConfigField("String", "SUPABASE_URL", "\"${localProperties.getProperty("SUPABASE_URL", "")}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"${localProperties.getProperty("SUPABASE_ANON_KEY", "")}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("androidx.activity:activity-compose:1.9.1")
    implementation("androidx.navigation:navigation-compose:2.7.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.4")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
    implementation("io.coil-kt:coil-compose:2.6.0")

    // Reels (0050_reels.sql) -- primer reproductor de vídeo real de toda la
    // app. Media3/ExoPlayer (AndroidX, Apache 2.0, gratuito) en vez de
    // VideoView (API antigua, peor soporte de formatos/controles) -- mismo
    // criterio de "herramienta gratuita/abierta antes que de pago" ya
    // aplicado al resto de este proyecto (osmdroid en vez de Google Maps).
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")

    // "Directo" (0056_live_streams.sql) -- LiveKit (WebRTC, Apache 2.0,
    // SDKs open-source), motor elegido explícitamente por el usuario
    // (LiveKit Cloud, frente a self-hosted) para no montar infraestructura
    // propia de streaming en vivo sobre un proyecto ya grande.
    implementation("io.livekit:livekit-android:2.28.0")

    // Jetpack Compose
    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material:material-icons-extended")

    // UWB (equivalente Android de NearbyInteraction). Requiere dispositivo
    // compatible: Pixel 6 Pro+, Galaxy S21 Ultra+ y similares — no todos los
    // Android 12+ tienen el chip, igual que no todos los iPhone tienen U1/U2.
    implementation("androidx.core.uwb:uwb:1.0.0-alpha08")

    // Nearby Connections: canal de arranque para intercambiar direcciones UWB,
    // equivalente al uso de MultipeerConnectivity en la versión iOS.
    implementation("com.google.android.gms:play-services-nearby:19.3.0")

    // "Find" (mapa de ubicaciones públicas) — hallazgo real: no existía
    // ningún mapa real en ninguna plataforma, solo un texto de relleno en
    // iOS. osmdroid (OpenStreetMap) en vez de Google Maps: preferencia
    // explícita del usuario de herramientas abiertas antes que de pago —
    // Google Maps exige una API key facturable, OSM no.
    implementation("org.osmdroid:osmdroid-android:6.1.20")

    // CameraX: vista previa de la cámara trasera (equivalente a AVFoundation en iOS).
    val cameraxVersion = "1.3.4"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")
    // CameraX expone ProcessCameraProvider.getInstance() como ListenableFuture;
    // camera-core solo trae el shim listenablefuture:1.0, que no incluye la
    // clase completa com.google.common.util.concurrent.ListenableFuture que
    // usa el compilador aquí — se necesita Guava completa en el classpath.
    implementation("com.google.guava:guava:32.1.3-android")

    // Visor 3D de avatares reales (SceneView, envoltorio Compose-nativo open
    // source sobre Google Filament) — reemplaza el círculo con gradiente de
    // PlaceholderAvatarProvider y el busto SVG plano del prototipo HTML.
    // Preferencia explícita del usuario: nada de SDKs de terceros de pago
    // (Ready Player Me, etc.) — los modelos 3D en sí son packs CC0
    // (ITHappy Creative Characters, Quaternius Universal Base Characters),
    // no un servicio con el que la app tenga que hablar en tiempo real.
    implementation("io.github.sceneview:sceneview:2.3.0")

    // Push real (FCM) -- equivalente Android de PushTokenManager.swift/
    // AppDelegate.swift. La librería compila igual sin google-services.json
    // (ver comentario junto al apply(plugin = ...) más arriba); sin él
    // simplemente no llega ningún push hasta que exista el proyecto Firebase.
    implementation(platform("com.google.firebase:firebase-bom:34.18.0"))
    implementation("com.google.firebase:firebase-messaging")

    // Código QR de perfil real, comparado con Snapchat (Snapcode)/
    // Instagram (Nametag)/WhatsApp -- ZXing core es Java puro (sin
    // dependencias de UI Android), MIT/Apache 2.0, gratis, mismo criterio
    // de herramientas open-source explícito del usuario ya usado con
    // osmdroid más arriba (frente a alternativas de pago). Solo el
    // generador esta ronda -- ver PerfilScreen.kt.
    implementation("com.google.zxing:core:3.5.3")

    // Supabase (mismo backend que iOS)
    implementation(platform("io.github.jan-tennert.supabase:bom:2.5.4"))
    implementation("io.github.jan-tennert.supabase:postgrest-kt")
    implementation("io.github.jan-tennert.supabase:realtime-kt")
    implementation("io.github.jan-tennert.supabase:gotrue-kt")
    implementation("io.github.jan-tennert.supabase:functions-kt")
    implementation("io.github.jan-tennert.supabase:storage-kt")
    implementation("io.ktor:ktor-client-okhttp:2.3.12")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
