# SOCIAL — proyecto completo (Fases 1-7 + iOS/Android)

App de descubrimiento social físico: detecta personas cercanas por UWB,
muestra su avatar 3D en la cámara, permite enviar "socials" y chatear con
una barra de compatibilidad y duelos generados por IA. Existe en dos
implementaciones nativas paralelas: **iOS (Swift/SwiftUI)** y
**Android (Kotlin/Jetpack Compose)**, con el mismo backend Supabase.

**Actualizado por el `/loop` autónomo — este README estaba desactualizado
desde antes de que existiera la implementación Android.** Estado real por
plataforma, verificado, no supuesto:

- **Android: COMPILA Y EJECUTA de verdad en este entorno.** JDK 17 +
  Android SDK (API 34) + Gradle 8.7 instalados sin admin en Windows.
  `./gradlew assembleDebug`/`assembleRelease` compilan limpio y se han
  verificado repetidamente instalando y ejecutando en un emulador real
  (AVD Pixel 5, API 33), con logcat inspeccionado en cada pasada para
  confirmar ausencia de crashes. Esto NO es una limitación de esfuerzo que
  quedara pendiente — ya está resuelto y verificado con evidencia real.
- **iOS: bloqueado de forma permanente en este entorno.** Xcode no existe
  para Windows y NearbyInteraction (UWB) es una API exclusiva de iOS — no
  hay forma de compilar, firmar ni instalar esta app en un iPhone sin un
  Mac (propio, prestado, o un runner macOS en la nube). Esto sí es un
  límite de plataforma real, no de esfuerzo. El código iOS se mantiene en
  paridad con Android pero sin verificación de compilador.

Ver `LOOP_STATE.md` para el registro completo, pasada a pasada, de bugs
encontrados y corregidos, y `legal/` para el estado real (no aspiracional)
de seguridad y cumplimiento antes de publicar.

## Estructura

```
Social/
├── App/SocialApp.swift              → punto de entrada (RootTabView)
├── Proximity/                       → Fase 1: motor UWB
│   ├── PeerToken.swift
│   ├── HeadingProvider.swift
│   └── SocialProximity.swift
├── Camera/                          → Fase 1: pantalla "Social"
│   ├── CameraPreviewView.swift
│   ├── PeerMarkerView.swift
│   └── SocialCameraView.swift
├── Backend/                         → Fase 2: cliente Supabase
│   ├── SupabaseManager.swift
│   ├── Config.example.plist         → copiar a Config.plist con tus claves
│   └── Models.swift
├── Avatar/                          → Fase 3: avatares
│   ├── AvatarProvider.swift         → interfaz (protocolo)
│   ├── PlaceholderAvatarProvider.swift → implementación temporal, aislada
│   ├── ClothingStore.swift          → catálogo de ropa (StoreKit 2)
│   └── SelfieConsentView.swift
├── Screens/                         → Fase 4: 5 pestañas
│   ├── RootTabView.swift
│   ├── Home/, Match/, Avisos/, Perfil/  → View + ViewModel cada una
├── Chat/                            → Fase 5: socials + chat + compatibilidad
├── Duels/                           → Fase 6: duelos + IA
├── Event/                           → Fase 7: modo evento
├── Safety/                          → Fase 7: seguridad
└── Info.plist

project.yml                          → definición del proyecto para XcodeGen
.github/workflows/build.yml          → compila en un runner macOS de GitHub Actions

Android/                              → implementación Kotlin/Jetpack Compose,
                                         misma estructura por carpeta que Social/
                                         (screens/, chat/, duels/, event/,
                                         safety/, proximity/, camera/, backend/)

supabase/
├── migrations/
│   ├── 0001_schema.sql              → las 13+ tablas del producto
│   ├── 0002_rls.sql                 → Row Level Security (4 reglas exigidas)
│   ├── 0003_safety.sql              → blocks, reports, events, event_attendees
│   ├── 0004_ai_usage.sql            → rate-limit de la Edge Function duel-ai
│   ├── 0005_analytics.sql           → analytics_events + event_density()
│   ├── 0006_notification_triggers.sql → productores reales de `notifications`
│   └── 0007_likes.sql               → tabla `likes` real + trigger de like_count
└── functions/duel-ai/index.ts       → Edge Function: proxy seguro a Anthropic

legal/
├── privacy_policy_es.md
├── app_store_permission_texts.md
├── app_store_listing.md
├── app_store_submission_checklist.md
├── security_checklist.md
├── scaling_notes.md
└── uwb_reliability_notes.md
```

## Cómo montarlo en Xcode (cuando tengas un Mac)

El proyecto usa **XcodeGen**: en vez de un `.xcodeproj` escrito a mano (frágil)
o de arrastrar archivos uno a uno, `project.yml` describe el proyecto y
XcodeGen genera un `.xcodeproj` válido de forma determinista.

1. Instala XcodeGen una vez: `brew install xcodegen`
2. Desde la raíz del repo: `xcodegen generate` → crea `Social.xcodeproj`.
3. Ábrelo: `open Social.xcodeproj`.
4. Copia `Social/Backend/Config.example.plist` a `Social/Backend/Config.plist`
   y rellena `SUPABASE_URL` y `SUPABASE_ANON_KEY` (la clave de Anthropic ya NO
   va aquí, ver más abajo). `Config.plist` está en `.gitignore`.
5. En **Signing & Capabilities**, activa tu equipo de desarrollo (Apple ID
   gratuito sirve para probar en tu propio iPhone; publicar en App Store
   requiere el Apple Developer Program de pago, 99 USD/año).
6. Corre las migraciones en tu proyecto Supabase, en orden (las 7, no solo
   las 3 primeras): `0001_schema.sql` → `0002_rls.sql` → `0003_safety.sql`
   → `0004_ai_usage.sql` → `0005_analytics.sql` →
   `0006_notification_triggers.sql` → `0007_likes.sql`.
7. Despliega la Edge Function que protege la clave de Anthropic:
   ```
   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
   supabase functions deploy duel-ai
   ```

## Cómo montarlo en Android (ya funciona en Windows, sin Mac)

A diferencia de iOS, esto SÍ se ha hecho y verificado en este entorno:

1. JDK 17, Android SDK (cmdline-tools, platform 34, build-tools 34.0.0) y
   Gradle 8.7 — todo instalable sin permisos de administrador en Windows
   (zips, no instaladores MSI).
2. Copia `Android/local.properties.example` (si existe) o crea
   `Android/local.properties` con `sdk.dir` apuntando a tu Android SDK y
   `SUPABASE_URL`/`SUPABASE_ANON_KEY`.
3. Desde `Android/`: `./gradlew assembleDebug` (o `assembleRelease`).
4. Instala en un emulador o dispositivo real: `adb install -r
   app/build/outputs/apk/debug/app-debug.apk`.

## Compilar sin Mac propio: CI en GitHub Actions (solo iOS)

`.github/workflows/build.yml` compila el proyecto en un runner macOS de
GitHub cada vez que subes el repo — permite **verificar que compila** sin
tener tu propio Mac. Límites reales:

- Compila para el **simulador**, sin firma. No instala en un iPhone físico ni
  sube nada a App Store — eso requiere un Mac con tu cuenta de Apple Developer.
- NearbyInteraction (Fase 1) no funciona en el simulador de todos modos: este
  CI confirma que el código compila, no que la app funcione en el mundo real.
- Los runners macOS consumen minutos de Actions más rápido que los de Linux;
  en un repo público de GitHub son gratis.

Para probar de verdad en iPhones no hay atajo: hace falta un Mac con Xcode
abierto y el iPhone conectado por cable.

## Cómo probar cada fase

| Fase | Cómo probarla | Qué deberías ver |
|---|---|---|
| 1 · UWB | Instala en 2 iPhone 11+, ábrelos cerca uno del otro | Contador de densidad, marcador flotante, distancia en metros |
| 2 · Backend | Migraciones aplicadas en Supabase | Las tablas aparecen en el dashboard, RLS activado (candado verde) |
| 3 · Avatares | Completa el onboarding con una selfie | Con `PlaceholderAvatarProvider` verás un círculo de color, no un avatar 3D real — así hasta integrar Avaturn/MetaPerson |
| 4 · Pantallas | Navega las 5 pestañas | Home con feed, Match en cuadrícula, Avisos con lista, Perfil con 6 subsecciones |
| 5 · Chat | Envía un social entre dos cuentas de prueba y acéptalo | Se abre el chat, la barra de compatibilidad se mueve en vivo en ambos dispositivos |
| 6 · Duelos | Inicia un duelo desde un chat (con `duel-ai` desplegada) | 5 preguntas generadas por IA, resultado con delta y explicación al terminar |
| 7 · Evento/seguridad | Activa modo invisible desde la cámara (Social) | Modo invisible solo vive ahí (efecto real sobre el motor UWB); denuncia/bloqueo se acceden desde el `SafetyToolbar` flotante en las otras 4 pestañas, o al tocar a un peer detectado en la cámara |

**El simulador de iOS no soporta NearbyInteraction ni cámara real** — la Fase 1
solo se puede probar en dispositivos físicos.

## Qué NO está verificado (y por qué)

Esta sección es específica de **iOS** — la compilación Android SÍ está
verificada de verdad en este entorno (ver arriba), no es un límite pendiente.

- **Compilación real de iOS**: sin Mac aquí, no he ejecutado `xcodegen
  generate` ni `xcodebuild`. El workflow de CI está listo para hacerlo en
  cuanto subas el repo a GitHub — esa es tu primera señal real de si
  compila.
- **Avaturn / MetaPerson**: no se integró ningún SDK real (ver el comentario
  al inicio de `AvatarProvider.swift`) porque no tengo forma de confirmar sus
  firmas actuales desde aquí. `PlaceholderAvatarProvider` es el sustituto
  aislado, listo para reemplazar.
- **Modelo de Anthropic**: el prompt original pedía `claude-sonnet-4-6`, que
  no es un identificador real. Se usó `claude-sonnet-4-5` — confírmalo contra
  la documentación de Anthropic antes de publicar.
- **`functions.invoke` en supabase-swift**: el nombre exacto del método puede
  variar según la versión del paquete. Está aislado en
  `AnthropicDuelService.invokeDuelAI` — si no compila, es el único sitio a tocar.
- **Verificación de cuenta** (selfie vs. avatar): dejada como placeholder en
  `SafetyManager.requestVerification`, requiere un servicio de comparación en
  el backend fuera del alcance de código cliente.

## Siguiente paso recomendado

1. Sube este repo a GitHub (privado o público) y deja que `build.yml` corra —
   es tu primera confirmación real de que el código compila, sin necesitar
   Mac propio todavía.
2. Consigue acceso a un Mac (propio, prestado, o alquilado por horas) para el
   paso que el CI no puede hacer: instalar en un iPhone físico y probar UWB.
3. Crea las cuentas de Supabase, Avaturn/MetaPerson y Anthropic, y despliega
   la Edge Function `duel-ai`.
4. Prueba la Fase 1 en dos iPhones físicos — es el hito que decide si el
   resto del proyecto tiene sentido, según los tiempos ya discutidos.
