# SOCIAL — Android

Contraparte Android de la app iOS en `../Social/`. Misma arquitectura de
producto (cámara como pantalla de inicio, motor de proximidad con las mismas
protecciones de seguridad/fiabilidad), backend Supabase compartido.

## Diferencia clave frente a iOS: esto SÍ se puede compilar sin Mac

Android Studio + el SDK de Android corren de forma nativa en Windows. A
diferencia de Xcode, no hay bloqueo de plataforma aquí — el paso pendiente
es instalar Android Studio (o el SDK command-line + Gradle) en esta misma
máquina y ejecutar `gradlew build`.

**Estado actual: compila de verdad.** JDK 17, Android SDK (platform 34,
build-tools 34.0.0) y el wrapper de Gradle 8.7 están instalados en esta
máquina. `./gradlew assembleDebug` genera un `app-debug.apk` real e
instalable. Se corrigieron 6 errores reales de compilador que las notas de
honestidad de este documento ya habían señalado como "no verificado" —
quedaron confirmados en cuanto hubo un compilador real disponible:

- `GoTrue` → la clase real en supabase-kt 2.5.4 es `Auth` (mismo paquete).
- `FilterOperator` vive en `postgrest.query.filter`, no en `postgrest.query`.
- `bodyAsText()` de Ktor necesita su propio import explícito.
- Un import directo de `weight` sombreaba la extensión `RowScope.weight`.
- Faltaba `import androidx.compose.runtime.getValue` para el delegado `by`
  sobre `State<T>` en `RootTabView.kt`.
- **El más importante**: `UwbDevice.createForAddress()` espera un `String`,
  no un `UwbAddress` — y además ambos lados del ranging llamaban a
  `controleeSessionScope()`, cuando `CONFIG_UNICAST_DS_TWR` exige un
  controller y un controlee. Ver la sección de UWB más abajo.

## Compatibilidad de dispositivos

- **minSdk 26 (Android 8), no 31.** UWB por sí solo exige Android 12, pero
  la app entera no debería excluir a nadie por debajo de eso. `AndroidManifest.xml`
  usa `tools:overrideLibrary` para permitir que el manifest de
  `androidx.core.uwb` (que sí exige 31) se fusione con un minSdk más bajo, y
  `SocialProximity.kt` comprueba `Build.VERSION.SDK_INT` antes de tocar
  cualquier símbolo de UWB — en Android 8-11 la app instala y funciona
  normal, solo la pestaña Social pierde la detección física con un mensaje
  claro, igual que en un dispositivo sin chip.
- **Chip UWB**: independiente de la versión de Android, solo algunos modelos
  lo tienen (Pixel 6 Pro+, Galaxy S21 Ultra+…). Mismo criterio que con U1/U2
  en iOS — no se puede saber en tiempo de compilación, solo en tiempo real
  contra el hardware.

## Cómo compilarlo

1. Instala JDK 17 y Android Studio (o el SDK command-line: `sdkmanager`).
2. Crea `Android/local.properties` con `SUPABASE_URL` y `SUPABASE_ANON_KEY`
   (no lo subas a git, ya está en `.gitignore`).
3. Desde `Android/`: `./gradlew build` (Android Studio lo hace automáticamente
   al abrir el proyecto).
4. Conecta un Android 12+ con chip UWB (Pixel 6 Pro+, Galaxy S21 Ultra+ y
   similares) — igual que con iPhone 11+/U1, no todos los Android tienen el
   chip, y el código degrada con un mensaje claro cuando falta.

## Qué hay ya escrito

- **Motor de proximidad** (`proximity/SocialProximity.kt`) con las mismas
  6 protecciones que la versión iOS: filtro de paso bajo, watchdog de datos
  obsoletos, límite de sesiones UWB simultáneas (batería en eventos),
  reintento automático si el ranging se invalida, filtrado de bloqueados a
  nivel de motor, rate-limit de reconexión.
- **Backend** (`backend/SupabaseManager.kt`, `backend/model/Models.kt`):
  mismo proyecto Supabase que iOS, mismas tablas.
- **Las 5 pestañas** (`screens/RootTabView.kt`): Home, Match, Social, Avisos,
  Perfil, cada una con su ViewModel — mismo patrón MVVM que iOS. Avisos
  incluye Supabase Realtime en vivo.
- **Cámara real** (`camera/CameraPreview.kt` con CameraX, `camera/PeerMarker.kt`,
  `camera/SocialCameraScreen.kt`): vista previa en vivo + marcadores
  flotantes posicionados por ángulo/distancia UWB + contador de densidad +
  modo invisible real en un toque — paridad funcional completa con
  `SocialCameraView.swift`.

- **Chat en tiempo real** (`chat/ChatViewModel.kt`, `chat/ChatScreen.kt`):
  barra de compatibilidad con votos +1/+10/+100, Realtime en vivo.
- **Duelos con IA** (`duels/AnthropicDuelService.kt`, `DuelViewModel.kt`,
  `DuelScreen.kt`): llama a la misma Edge Function `duel-ai` que ya protege
  la clave de Anthropic y limita el uso a 20/hora — cero lógica de seguridad
  duplicada entre plataformas.

- **Seguridad** (`safety/SafetyManager.kt`, `safety/ReportSheet.kt`): bloqueo,
  denuncia y modo invisible real (persistencia en `profiles` + corte del
  anuncio Multipeer/UWB en el mismo toque, igual que en iOS), cableado ya en
  `SocialCameraScreen`.
- **Modo Evento** (`event/EventModeViewModel.kt`, `EventModeScreen.kt`):
  detección de evento activo por ubicación + ranking de socials.

## Qué falta para paridad completa con iOS

- [x] Navegación real chat/duelo (`RootTabView.kt` con `NavHost`): Avisos
  navega al chat correspondiente (`chat/{chatId}`) al tocar una notificación
  de social; rutas de duelo (`duel/{chatId}/{opponentId}`) ya en el grafo.
  Asume que el backend rellena `payload.chat_id` en la notificación — ver
  aviso de honestidad en `AvisosScreen.kt`.
- [x] `DuelEntryPoint.kt` carga las `profile_sections` reales del oponente
  antes de arrancar el duelo (con spinner mientras carga) — ya no se pasa
  una lista vacía.
- [x] **Resuelto en una pasada posterior del `/loop`**: `EventModeViewModel.loadRanking`
  ya hace el join real `event_attendees + profiles` (`Columns.raw("social_count,
  profile_id, profiles(display_name)")`), verificado contra el bytecode real
  de `postgrest-kt` 2.5.4 — este párrafo describía un estado ya superado.
- [x] Verificación de cuenta: placeholder honesto añadido
  (`SafetyManager.requestVerification`), mismo criterio que la versión iOS
  — señala que requiere una Edge Function backend, no simula el resultado.
- [x] **Resuelto**: la firma exacta de `update{}` de `supabase-kt` en
  `AvisosViewModel.markRead` ya está verificada — compila limpio contra
  supabase-kt 2.5.4 real (ver comentario en el propio archivo). Este párrafo
  también describía un estado ya superado.
- `RootTabView.kt` usa `Tab.values()`, marcado como deprecado en Kotlin
  reciente a favor de `Tab.entries` — funciona, pero conviene actualizarlo
  al fijar la versión exacta de Kotlin con la que se compile de verdad.

## Cómo se resolvió `complexChannel` — y el bug de fondo que escondía

Antes: `complexChannel` se dejaba en `null` con un aviso de honestidad
explicando que la negociación fuera de banda no estaba verificada. Con
compilador real disponible, se pudo inspeccionar el bytecode de
`androidx.core.uwb:uwb:1.0.0-alpha08` directamente (no documentación) y
salieron dos hallazgos:

1. **`UwbControllerSessionScope.uwbComplexChannel` existe y lo asigna el
   propio framework** — no hay que inventar canal ni preámbulo, solo leerlo
   del lado que actúa de controller y enviárselo al controlee por Nearby
   Connections antes de que este arranque el ranging.
2. **El código real tenía un problema más grave**: los dos lados de cada
   conexión llamaban a `uwbManager.controleeSessionScope()` — pero
   `CONFIG_UNICAST_DS_TWR` (el modo usado) exige que de cada dos
   dispositivos uno sea controller y el otro controlee. Con ambos lados de
   controlee, el ranging nunca habría llegado a medir nada en hardware real.
   Se corrigió asignando el rol de forma determinista: el UUID menor de los
   dos peers actúa de controller, así ambos lados llegan a la misma
   conclusión sin necesidad de negociarlo aparte.
3. De paso salió un tercer bug relacionado: `sessionId` se calculaba como
   `peerId.id.hashCode()` donde `peerId` era **el ID del otro peer** — cada
   lado de la conexión calculaba un hash distinto, así que controller y
   controlee nunca habrían coincidido en el identificador de sesión. Ahora
   se deriva de forma simétrica a partir de ambos UUID ordenados
   (`sharedSessionId`), igual en los dos extremos.

Los tres hallazgos están en `SocialProximity.kt` con comentarios explicando
la corrección. Es el ejemplo más claro de esta sesión de por qué señalar
honestamente "esto no está verificado" en vez de simular una implementación
que parece correcta importa: en cuanto hubo un compilador real, ese aviso
llevó directo al bug de fondo.
