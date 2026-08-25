# Estado del loop autónomo — SOCIAL

Este documento se reescribe en cada pasada del `/loop` con lo más reciente.
Sirve como "prompt vivo": recoge qué se ha hecho, qué está verificado y qué
sigue pendiente, para que cada pasada parta del estado real en vez de
repetir trabajo o perder contexto.

## Objetivo del proyecto
Construir SOCIAL: app de descubrimiento social por proximidad física (UWB),
avatares 3D, chat con compatibilidad en vivo, duelos con IA, Modo Evento y
seguridad — para iOS y Android, compitiendo con Instagram/TikTok/Snapchat en
su nicho físico. Regla no negociable: honestidad técnica — nunca simular
código no verificado, señalarlo explícitamente si no se puede confirmar.

**Regla de rendimiento del ordenador del usuario (2026-08-21)**: al terminar
de usar el emulador o el daemon de Gradle en una pasada, cerrarlos antes de
programar el siguiente `ScheduleWakeup` en vez de dejarlos corriendo de
fondo — `adb emu kill` y `./gradlew --stop`. La siguiente pasada que
necesite verificar en el emulador simplemente lo vuelve a arrancar (más
lento por pasada, pero no consume recursos entre pasadas).

## Estado real por plataforma
- **Android**: COMPILA y EJECUTA de verdad. JDK 17 + Android SDK (API 34) +
  Gradle 8.7 instalados localmente. `assembleDebug` genera `app-debug.apk`
  instalable. Probado en emulador real (Pixel 5, API 33, AVD `social_test`)
  — PID estable, navegación de 5 pestañas sin crash.
- **CORRECCIÓN IMPORTANTE (esta pasada): sí hay acceso real a internet en
  este entorno.** Gradle resolvió y descargó `storage-kt:2.5.4` en caliente
  sin `--offline`. Todas las pasadas anteriores asumían (incorrectamente,
  nunca verificado explícitamente hasta ahora) que Historias/chat
  multimedia/avatar/fotos de posts estaban bloqueados por falta de red —
  el bloqueo real era solo no haber añadido la dependencia `storage-kt` ni
  el módulo Storage al proyecto, ya corregido esta pasada (ver más abajo).
  Sigue sin haber Postgres NATIVO instalable (bloqueado por UAC, límite
  distinto y sí confirmado) ni Xcode/Mac (límite de plataforma real).
  **CORRECCIÓN IMPORTANTE (pasada posterior)**: aunque no hay Postgres
  nativo, sí hay Postgres REAL disponible vía `@electric-sql/pglite`
  (WASM, corre sobre Node) — ver `supabase/local_verify/`, que ejecuta
  las 35 migraciones y prueba los triggers de seguridad con datos reales,
  no solo relectura. Esto NO sustituye probar contra un proyecto Supabase
  real (RLS vía PostgREST, GoTrue, Storage/Realtime completos), pero es
  una verificación real que antes se creía imposible en este entorno. A
  partir de ahora, usar `./gradlew assembleDebug` sin `--offline` cuando
  se añadan dependencias nuevas.
- **iOS**: bloqueado de forma permanente en este entorno — no hay Mac ni
  Xcode ni forma de compilar/firmar/subir SwiftUI/NearbyInteraction en
  Windows. Esto no es un problema que "trabajar más" resuelva; es un límite
  de plataforma. El código se mantiene en paridad con Android pero sin
  verificación de compilador.

## Bugs reales encontrados y corregidos esta sesión (por orden)
1. Falta `android.useAndroidX`/`enableJetifier` en gradle.properties.
2. Faltaban recursos (tema, icono) — creados desde cero.
3. `GoTrue` → la clase real en supabase-kt 2.5.4 es `Auth`.
4. `FilterOperator` en paquete incompleto (`postgrest.query` → `.query.filter`).
5. Import de `weight` sombreaba la extensión `RowScope.weight`.
6. Faltaba `import androidx.compose.runtime.getValue` para delegado `by`.
7. **UWB — bug arquitectónico real**: ambos lados de cada conexión se
   configuraban como "controlee"; `CONFIG_UNICAST_DS_TWR` exige un
   controller y un controlee. Corregido con rol determinista por UUID +
   `sessionId` compartido (antes cada lado calculaba un hash distinto).
8. `UwbDevice.createForAddress()` esperaba `String`, no `UwbAddress`.
9. Faltaba el permiso `INTERNET` en el manifest — la app CRASHEABA de
   verdad al primer intento de red (encontrado ejecutando en emulador).
10. `errorMessage` calculado en 6 ViewModels pero nunca mostrado en pantalla
    (Home/Match/Avisos/Perfil) — spinners infinitos silenciosos.
11. **Modo Evento estaba huérfano en AMBAS plataformas**: el código existía
    (`EventModeView.swift`/`EventModeBanner.kt`) pero nunca se montaba en
    ninguna pantalla real. Cableado con un proveedor de ubicación mínimo.
12. **Fallo de privacidad real**: Match y Home traían perfiles sin filtrar
    modo invisible ni excluir al propio usuario, en ambas plataformas.
13. Android nunca implementó "Recomendados" en Home (el docstring mentía) —
    implementado con la misma heurística que iOS.
14. `DuelView`/`DuelScreen` sin punto de entrada real en ninguna plataforma
    (mismo patrón que #11, Modo Evento) — corregido con botón "Retar a
    duelo" en ChatScreen/ChatView.
19. **Android nunca tuvo el overlay global de denuncia** (`SafetyToolbar`):
    iOS lo monta en `RootTabView.swift` visible en las 4 pestañas que no son
    Social (principio "seguridad primero"); Android no tenía nada — el
    docstring de `ReportSheet.kt` ya afirmaba (falsamente) ser "accesible
    desde cualquier pantalla", pero solo se abría desde el peer-tap de la
    cámara. Creado `SafetyToolbar.kt` (mismo comportamiento y misma
    limitación honesta que iOS: sin un target concreto en contexto,
    `reportedId` usa el propio usuario) y cableado en `RootTabView.kt` con
    la misma condición `currentRoute != Tab.SOCIAL.route`.
15. `ChatScreen.kt` mostraba un texto fijo hardcodeado como "actividad
    sugerida" en vez de consultar la tabla `activities` real (iOS sí lo
    hacía) — corregido, ahora Android también consulta de verdad.
16. Falta `limit(50)` en el ranking de Modo Evento en Android (sí presente
    en iOS) — consulta sin tope en el caso de uso con más asistentes a la
    vez de toda la app.
17. **La tabla `notifications` nunca recibía ninguna fila nueva** — sin
    trigger en el servidor ni política RLS de insert para el cliente. La
    pantalla "Avisos", completamente cableada en ambas plataformas desde
    hace varias pasadas, estaría siempre vacía contra un proyecto real.
    Corregido con 4 funciones trigger `security definer` en
    `0006_notification_triggers.sql` (socials/follows/compat_requests/duels).
18. **El botón de "like" era enteramente falso en ambas plataformas**: no
    existía tabla `likes`, el contador solo se incrementaba en memoria y se
    perdía en el siguiente `load()` — el propio código ya tenía un
    comentario (ahora corregido) que asumía un "backend" que nunca se
    construyó. Corregido con `0007_likes.sql` (tabla `likes` + RLS +
    trigger que mantiene `posts.like_count` sincronizado) y `like()` real en
    `HomeViewModel.kt`/`HomeViewModel.swift`, con manejo correcto del caso
    "ya lo había dado" (constraint unique, 409 no es error de usuario).
    Completado además: 'like' ya era un `kind` válido en `notifications`
    (con icono/título ya construidos en AvisosViewModel) pero nunca tenía
    productor — añadido `trg_notify_new_like` al mismo `0007_likes.sql`,
    notificando al autor del post (sin auto-notificarse en self-like).

## Añadido esta sesión (no bugs, funcionalidad nueva)
- **Mensaje real de "confirma tu email" también al iniciar sesión**:
  `signIn()` siempre mostraba "email o contraseña incorrectos", incluso
  cuando la causa real era que el email todavía no estaba confirmado —
  justo el caso que `signUp()` ya avisa correctamente desde una pasada
  anterior, pero el login no lo distinguía, dando un mensaje engañoso a
  quien recién se registró. Heurística sobre el texto del error (busca
  "confirm") en vez de un código exacto verificado — mejor que el mensaje
  siempre-incorrecto de antes, aunque no sea infalible. **Android:
  COMPILADO OK, instalado y relanzado sin FATAL en el emulador real.**
  iOS con el mismo criterio, sin verificación de compilador real.
- **Onboarding de avatar en Android — cierra el hueco de paridad iOS/Android
  que quedaba documentado**: `SelfieConsentView.swift`/
  `OnboardingAvatarView.swift` ya se habían conectado en iOS (pasada
  anterior), pero Android nunca tuvo ningún archivo Avatar/Onboarding/
  Selfie en absoluto — se documentó explícitamente como "construir la
  feature entera, no conectarla" y quedó pendiente. Añadidos
  `SelfieConsentScreen.kt` + `AvatarOnboardingScreen.kt` (consentimiento →
  selector de foto → genera `avatar_config` con
  `PlaceholderAvatarProvider`-equivalente, color derivado localmente, sin
  fingir un motor 3D real) + disparo en `AppRoot.kt` cuando el perfil
  recién autenticado no tiene `avatar_config` — mismo patrón que
  `AppRootView.swift`. **COMPILADO OK (confirma también que
  `Icons.Filled.Face` sí existe en el set de iconos del proyecto, a
  diferencia de `Icons.Filled.Add` que falló hace varias pasadas),
  instalado y relanzado sin FATAL en el emulador real.** Android e iOS ya
  están a la par en este flujo.
- **Mismo hallazgo de `.limit()` extendido a las otras tres listas sin
  límite**: al corregir `ChatViewModel.loadHistory()`, se comprobaron las
  demás listas construidas esta sesión — `SocialsListViewModel`,
  `CompatSharesViewModel` y la consulta principal de `ChatListViewModel`
  (la de `chats`, no la de último mensaje, que ya tenía `limit(1)`)
  tampoco tenían `.limit()`, mismo descuido. Añadido `limit(100)`/
  `limit(200)` según el caso. **Android: COMPILADO OK, instalado y
  relanzado sin FATAL en el emulador real.** iOS con el mismo patrón, sin
  verificación de compilador real.
- **Límite real en la carga del historial de chat — hallazgo de
  escalabilidad**: `loadHistory()` no tenía `.limit()`, a diferencia del
  resto de consultas del proyecto (Home/Match/Search/Avisos, todas con
  `.limit()`) — abrir un chat largo traía el historial ENTERO cada vez.
  Ahora se piden los últimos 100 mensajes en orden descendente y se
  invierten para mostrar cronológicamente (un `limit()` con orden
  ascendente habría traído los 100 MÁS ANTIGUOS, no los recientes).
  Paginar hacia atrás (cargar más historial antiguo al hacer scroll) no se
  construye aquí — hueco real documentado, no un intento a medias.
  **Android: COMPILADO OK, instalado y relanzado sin FATAL en el emulador
  real.** iOS con el mismo patrón, sin verificación de compilador real.
- **Límites de longitud reales en campos de texto — hallazgo de robustez**:
  `comments.body` ya tenía un límite (1-500, 0008_comments.sql), pero
  `messages.body`, `posts.caption`, `profiles.display_name`/`bio` nunca lo
  tuvieron — un cliente modificado (o un bug) podía insertar texto de
  tamaño arbitrario, rompiendo el renderizado de burbujas de
  chat/tarjetas de post. `0023_text_length_limits.sql`: mensajes hasta
  2000 caracteres, captions hasta 2200 (mismo orden que Instagram),
  nombres 1-50, bio hasta 300 — límites generosos pero reales, no
  arbitrariamente estrictos. Añadida también validación en cliente del
  límite de nombre en `AuthViewModel.kt`/`.swift` (mismo criterio que el
  resto de esta sesión: dar un error claro en vez de que falle el insert
  del trigger `handle_new_user` con un mensaje de Postgres críptico).
  **Android: COMPILADO OK, instalado y relanzado sin FATAL en el emulador
  real.** iOS con el mismo criterio, sin verificación de compilador real.
- **Términos de servicio + aceptación obligatoria en el registro —
  hallazgo real, legalmente relevante**: no existía ni siquiera el
  documento de términos de servicio en `legal/` (solo había política de
  privacidad), y el registro dejaba crear una cuenta sin aceptar ningún
  término. Redactado `legal/terms_of_service_es.md` con el mismo criterio
  honesto que `privacy_policy_es.md` (borrador para revisión legal, no
  documento definitivo — cubre requisitos de edad, responsabilidad en
  encuentros físicos con desconocidos dado que SOCIAL es una app de
  proximidad, conducta prohibida, contenido publicado, cese de cuenta;
  jurisdicción explícitamente sin rellenar en vez de inventada). Empaquetado
  igual que la política de privacidad (assets/bundle). **Checkbox real
  obligatorio en `AuthScreen.kt`/`AuthView.swift`**: "Crear cuenta" queda
  deshabilitado hasta marcarla, con enlaces "Ver términos"/"Ver privacidad"
  que abren el documento completo en un diálogo/sheet sin salir del
  registro. Añadida también entrada "Términos de servicio" en Ajustes.
  **Android: COMPILADO OK, instalado y VERIFICADO VISUALMENTE en el
  emulador real** (captura real de la pantalla de registro con la casilla,
  los enlaces y "Crear cuenta" deshabilitado). iOS con el mismo patrón
  (`Toggle` + `.sheet`), sin verificación de compilador real.
- **Política de privacidad accesible dentro de la app — hallazgo real y
  legalmente relevante**: `legal/privacy_policy_es.md` (el documento que
  ya se auditó y corrigió varias veces esta sesión) nunca se mostraba
  DENTRO de la app en ninguna plataforma — solo existía como archivo del
  repositorio. App Store/Play Store exigen que sea accesible desde la
  propia app. Copiado como recurso empaquetado: `assets/privacy_policy_es.md`
  en Android, recurso del bundle vía `project.yml` en iOS — texto plano,
  sin renderer de Markdown (dependencia innecesaria solo para esto).
  **Nota de mantenimiento explícita en ambos archivos**: si se edita
  `legal/privacy_policy_es.md`, hay que volver a copiarlo — no se lee en
  vivo del repositorio porque la app compilada no tiene acceso a él.
  Entrada nueva en Ajustes en ambas plataformas. **Android: COMPILADO OK,
  instalado y relanzado sin FATAL en el emulador real.** iOS con
  `Bundle.main.url(forResource:withExtension:)`, API estándar de
  Foundation, sin verificación de compilador real.
- **Cambiar contraseña estando dentro de la cuenta**: había recuperación
  por email (pasada anterior) pero ninguna forma de cambiar la contraseña
  sin cerrar sesión y pasar por el email — cualquier app real lo permite
  desde Ajustes. Añadido `ChangePasswordViewModel.kt`/`.swift`
  (`auth.updateUser { password = ... }`, **verificado contra el
  compilador real en Android**) + formulario en `AjustesScreen.kt`/
  `AjustesView.swift`. **Android: COMPILADO OK, instalado y relanzado sin
  FATAL en el emulador real.** iOS con `auth.update(user: UserAttributes(...))`,
  aviso de honestidad explícito sobre esa forma exacta, sin verificación
  de compilador real.
- **Recuperar contraseña**: hallazgo real, completa el flujo de auth de
  esta sesión — no existía NINGÚN flujo de "olvidé mi contraseña" en
  ninguna plataforma. Sin esto, un usuario que olvida su contraseña se
  quedaría bloqueado fuera de su cuenta para siempre, sin forma de
  recuperarla desde la app. Añadido `resetPassword()` en
  `AuthViewModel.kt`/`.swift` (`auth.resetPasswordForEmail`, **verificado
  contra el compilador real en Android**) + enlace "¿Olvidaste tu
  contraseña?" en `AuthScreen.kt`/`AuthView.swift`, visible solo en modo
  login. Mensaje neutro ("si existe una cuenta con ese email...") en vez
  de confirmar/negar si el email está registrado — no filtra qué emails
  existen. **Android: COMPILADO OK, instalado y relanzado sin FATAL en el
  emulador real.** iOS con el mismo método documentado de supabase-swift,
  sin verificación de compilador real.
- **Aviso real de "confirma tu email" en el registro**: hallazgo real — si
  el proyecto Supabase exige confirmación de email (configuración
  habitual por defecto), `signUp` crea la cuenta pero no la sesión; sin
  ningún mensaje, la pantalla de registro se quedaría igual sin explicar
  por qué no entraste. Capturado el valor de retorno de `signUpWith` en
  vez de descartarlo — **compilador confirmó que es nulable**, verificando
  de verdad que este caso existe en supabase-kt (no era una suposición sin
  comprobar). Mensaje real "Te hemos enviado un email para confirmar tu
  cuenta..." en `AuthScreen.kt`. **Android: COMPILADO OK, instalado y
  relanzado sin FATAL en el emulador real.** iOS con el mismo criterio
  (comprobando si `auth.session` sigue siendo nil tras el signUp), aviso
  de honestidad explícito sobre la forma exacta de `AuthResponse` en
  supabase-swift, sin verificación de compilador real.
- **Borrar el propio mensaje**: tercera vez que aparece el mismo patrón en
  esta sesión (socials, compat_requests, ahora messages) — barrido
  sistemático de las 13 tablas del esquema buscando políticas de delete
  faltantes tras encontrar las dos primeras. `messages` no tenía NINGUNA,
  ni siquiera el propio remitente podía borrar un mensaje enviado por
  error. `0022_messages_delete.sql`: solo el remitente, "borrar para
  todos" (sin infraestructura de "ocultar solo para mí"). Mantener
  pulsado un mensaje propio lo borra (`combinedClickable` en Android,
  `.onLongPressGesture` en iOS) — el toque simple sigue abriendo el
  selector de reacciones. **Resto del barrido**: `profiles`/
  `profile_sections`/`posts`/`stories`/`follows` ya tenían `for all` (delete
  ya cubierto); `chats` sin delete es correcto por ahora (borrar un chat
  afectaría a ambas partes, distinto de "ocultar solo para mí", que no
  existe — no se improvisa esa decisión de diseño aquí);
  `compatibility_votes`/`duels`/`activities` son registros históricos,
  sin delete por diseño, no por descuido. **Android: COMPILADO OK
  (verificando `combinedClickable` contra el compilador real), instalado
  y relanzado sin FATAL en el emulador real.** iOS con
  `.onLongPressGesture`, sin verificación de compilador real.
- **Revocar el acceso a tu % de compatibilidad**: mismo patrón encontrado
  justo después de arreglar socials — `compat_requests` tampoco tenía
  NINGUNA política de delete. Una vez aceptada una solicitud, quien
  comparte su compatibilidad (`target_id`, ver
  `private.has_accepted_compat_request`) no tenía forma de revocarlo,
  nunca, ni siquiera desde la app entera. `0021_compat_requests_revoke.sql`:
  solo el dueño de la compatibilidad puede revocar — a diferencia de
  socials, esto NO es simétrico (quien pidió verla nunca concedió nada,
  no hay nada que revocar de su lado). Añadida pantalla nueva "Quién ve tu
  compatibilidad" (`CompatSharesViewModel.kt`/`.swift` +
  `CompatSharesScreen.kt`/`.swift`), entrada en Ajustes junto a los
  interruptores de privacidad de la pasada anterior. **Android: COMPILADO
  OK, instalado y relanzado sin FATAL en el emulador real.** iOS con el
  mismo patrón, sin verificación de compilador real.
- **Quitar un social aceptado**: hallazgo real encontrado justo al
  construir la lista de socials de esta misma pasada — `socials` no tenía
  NINGUNA política de delete, así que un vínculo aceptado era permanente
  para siempre (a diferencia de `follows`, que ya era `for all`).
  `0020_socials_delete.sql`: cualquiera de las dos partes puede deshacer
  el vínculo, mismo criterio que dejar de seguir. Botón "Quitar" real en
  `SocialsListScreen.kt`/`SocialsListView.swift`. **Android: COMPILADO OK
  (con un error real corregido en el camino: un import de `weight` que no
  existe como top-level, es una extensión de `RowScope` — el compilador lo
  señaló), instalado y relanzado sin FATAL en el emulador real.** iOS con
  el mismo patrón, sin verificación de compilador real.
- **Lista de socials aceptados**: "socials" (vínculo mutuo — requiere
  aceptación de ambas partes, distinto de "follow") es el concepto de
  relación central de la app, pero no había NINGUNA pantalla para ver la
  lista de socials aceptados en ninguna plataforma — el contador "Socials"
  ya existía desde hace varias pasadas, pero solo mostraba el número.
  Añadido `SocialsListViewModel.kt`/`.swift` + `SocialsListScreen.kt`/
  `SocialsListView.swift` (mismo patrón sin join embebido/FK ambigua que
  `DuelHistoryViewModel`/`ChatListViewModel`: dos columnas que referencian
  `profiles`, resuelto con una consulta por id). Entrada nueva "👥 Tus
  socials" en `PerfilScreen.kt`; en iOS, el propio contador "Socials" ahora
  es tocable. **Android: COMPILADO OK, instalado y relanzado sin FATAL en
  el emulador real.** iOS con el mismo patrón, sin verificación de
  compilador real.
- **"Find" — mapa de ubicaciones públicas real, no un texto de relleno**:
  hallazgo real — en iOS `showFind` abría un `.sheet` con un `Text("Find:
  mapa de ubicaciones públicas")` fijo, nunca un mapa; en Android no
  existía ni el punto de entrada. Con `location_public` ya activable de
  verdad (interruptor de esta misma pasada), tenía sentido construir el
  mapa. `FindLocationsViewModel.kt`/`.swift` consulta
  `profiles_select_public` (0002_rls.sql, ya expone `last_lat`/`last_lng`
  solo cuando `location_public = true`) con el mismo filtro de bloqueados
  ya aplicado en Match/Home/Search, filtrando en cliente las filas sin
  coordenadas reales (`location_public=true` no garantiza que alguien haya
  compartido una posición alguna vez). **OpenStreetMap (osmdroid) en
  Android en vez de Google Maps — preferencia explícita del usuario de
  herramientas abiertas antes que de pago (Google Maps exige API key
  facturable, OSM no)**; MapKit nativo de Apple en iOS (framework del
  sistema, no un SDK de terceros). Entrada nueva "🗺 Find" en
  `HomeScreen.kt`. **Android: COMPILADO OK (verificando de verdad contra
  el compilador real toda la superficie de osmdroid — `MapView`,
  `TileSourceFactory`, `Marker`, `GeoPoint`, sin precedente previo en el
  proyecto), instalado y relanzado sin FATAL en el emulador real.** iOS
  con `Map(coordinateRegion:annotationItems:)` (la forma de SwiftUI Map
  compatible con el deployment target real de iOS 16 — `Map(position:)`
  es exclusiva de iOS 17+), sin verificación de compilador real.
  **Nota de proceso**: a partir de esta pasada, la verificación visual
  profunda por captura ya no es posible sin credenciales reales de
  Supabase — el gate de sesión (`AppRoot`/`AppRootView`, pasada anterior)
  bloquea correctamente cualquier pantalla más allá del login sin una
  cuenta real. El compilador real sigue siendo la verificación principal.
- **Interruptores de privacidad (compatibilidad/ubicación públicas) —
  dato muerto activado**: `compat_public`/`location_public` se consultaban
  en Match/Home (para saber si mostrar el % de compatibilidad sin
  solicitarla) y "Find" (mapa de ubicaciones públicas), pero no existía
  NINGÚN interruptor en ninguna plataforma para activarlos — se quedaban
  en `false` para siempre, la única forma de cambiarlo habría sido
  escribir directamente en la base de datos. `profiles_update_own`
  (0002_rls.sql) ya permitía editar cualquier columna del propio perfil,
  solo faltaba la UI. Añadido `PrivacySettingsViewModel.kt`/`.swift` + dos
  `Switch`/`Toggle` reales en `AjustesScreen.kt`/`AjustesView.swift`, con
  actualización optimista y reversión si falla el guardado. **Android:
  COMPILADO OK (confirmando que `set(columnaVariable, valor)` en el DSL de
  `update{}` acepta un nombre de columna dinámico, no solo literales —
  sin precedente exacto antes en el proyecto), instalado y relanzado sin
  FATAL en el emulador real.** iOS con `Toggle`/`Binding` nativos de
  SwiftUI, sin verificación de compilador real.
- **Mensajes de voz — CIERRA POR COMPLETO "chat funcional con fotos, voz,
  reacciones, read receipts", las cuatro piezas del prompt original**:
  grabación nativa, sin SDK de terceros — `MediaRecorder`/`MediaPlayer`
  (Android) y `AVAudioRecorder`/`AVAudioPlayer` (iOS), AAC en contenedor
  .m4a. `0019_message_audio.sql`: columna `audio_url` separada de
  `media_url` a propósito (el cliente necesita distinguir reproductor de
  imagen explícitamente, no adivinar por la extensión), constraint
  `messages_has_content` ampliada a los tres campos. Permisos nuevos:
  `RECORD_AUDIO` en el manifest de Android, `NSMicrophoneUsageDescription`
  en el `Info.plist` de iOS — ninguno de los dos existía. `StorageUploader`
  generalizado para archivos arbitrarios (antes solo imágenes) en vez de
  duplicar la lógica de subida. Botón 🎙/⏹ en el compositor del chat
  (deshabilita el campo de texto mientras graba), burbuja "▶ Nota de voz"
  reproducible al tocar. **Android: COMPILADO OK (verificando de verdad
  contra el compilador real toda la superficie de `MediaRecorder`/
  `MediaPlayer`/`RequestPermission`), instalado y relanzado sin FATAL en
  el emulador real.** iOS con `AVAudioSession`/`AVAudioRecorder`/
  `AVAudioPlayer`, APIs documentadas de Apple, sin verificación de
  compilador real (límite de plataforma).
- **Reacciones a mensajes**: `0018_message_reactions.sql` — tabla nueva (no columna
  en `messages`, una reacción es por persona, mismo criterio que `likes`),
  con `chat_id` desnormalizado para poder filtrar con `eq` simple en vez
  de `isIn` (sin precedente verificado en este proyecto — mismo motivo por
  el que se evitó antes). RLS: solo miembros del chat ven/crean, solo el
  propio autor borra. Toggle real (like/unlike del emoji) en
  `ChatViewModel.kt`/`.swift`, con Realtime en vivo (`INSERT`/`DELETE` en
  `message_reactions`, además de lo ya existente). UI: tocar una burbuja
  abre un selector de 5 emojis; las reacciones existentes se agrupan con
  recuento, resaltadas si el usuario ya reaccionó. **Android: COMPILADO OK
  (con un error real corregido en el camino: usé un nombre de modifier
  inventado, `androidx_clickable_combined`, en vez de `Modifier.clickable`
  — el compilador lo señaló y se corrigió; también confirma
  `PostgresAction.Delete`/`oldRecord` como API real), instalado y
  relanzado sin FATAL en el emulador real.** iOS con el mismo patrón, con
  aviso de honestidad explícito sobre la forma exacta de `oldRecord` en
  supabase-swift (razonada por analogía, no verificada). (Voz, la última
  pieza, cerrada justo después — ver entrada de arriba.)
- **Pull-to-refresh completo en las cuatro listas restantes**: Home/Match
  ya lo tenían (`PullToRefreshContainer`/`.refreshable` en una pasada
  anterior); Avisos y "Tus chats" no, en ninguna plataforma. Añadido
  `AvisosViewModel.refresh()` (recarga sin volver a suscribirse a Realtime,
  evitando un canal duplicado — `start()` ya lo hace una vez) +
  `PullToRefreshContainer` en `AvisosScreen.kt`/`ChatListScreen.kt`, y
  `.refreshable` nativo en `AvisosView.swift`/`ChatListView.swift` (iOS,
  reutilizando el `load()` público ya existente). **Android: COMPILADO OK,
  instalado y relanzado sin FATAL en el emulador real.** iOS con API nativa
  de SwiftUI, sin verificación de compilador real.
- **Fecha relativa en Avisos (Android) — cierre de paridad, no nuevo en
  iOS**: mismo patrón que los posts — `AvisosScreen.kt` decodificaba
  `createdAt` pero nunca lo mostraba, cada aviso solo tenía título e
  icono. Al revisar el equivalente iOS se confirmó que `AvisosView.swift`
  YA mostraba `Text(entry.createdAt, style: .relative)` desde antes — solo
  Android tenía el hueco. Extraída la función `relativeTime()` de
  `HomeScreen.kt` a un util compartido (`util/TimeFormat.kt`) y reutilizada
  en `AvisosScreen.kt`. **COMPILADO OK, instalado y relanzado sin FATAL en
  el emulador real.** Sin cambios iOS — ya estaba bien.
- **Denunciar un comentario directamente**: mismo patrón que "Denunciar
  publicación" de la pasada anterior — solo existía denuncia global de
  usuario, ahora también por comentario concreto (sin columna nueva, se
  denuncia al autor con el id del comentario en los detalles). Botón "⋯"
  en comentarios ajenos, junto a "Borrar" en los propios, en
  `CommentsSheet.kt`/`CommentsView.swift`. **Android: COMPILADO OK,
  instalado y relanzado sin FATAL en el emulador real.** iOS con
  `.sheet(item:)` (disponible desde iOS 14, sin el límite de iOS 17+ ya
  documentado para `.navigationDestination(item:)`), sin verificación de
  compilador real.
- **Badge de verificación (✔️) — dato muerto activado**: `profiles.is_verified`
  se consultaba en varias pantallas (Match/Search/BlockedUsers/ProfileViewer)
  pero nunca se renderizaba como badge visual en ningún sitio, en ninguna
  plataforma — mismo patrón de "campo consultado pero nunca pintado" ya
  encontrado antes con avatares/contadores esta sesión. Añadido el
  checkmark junto al nombre en `PerfilScreen.kt`/`ProfileViewerScreen.kt`/
  `SearchScreen.kt` y sus equivalentes `PerfilView.swift`/
  `ProfileViewerView.swift`/`SearchView.swift`. **Android: COMPILADO OK,
  instalado y relanzado sin FATAL en el emulador real.** iOS con
  `checkmark.seal.fill`, símbolo SF real, sin verificación de compilador
  real. Nota: no hay ningún mecanismo real para marcar a alguien como
  verificado (`requestVerification()` sigue siendo un placeholder honesto
  que pide backend de comparación, ver SafetyManager) — esto solo cierra
  el hueco de renderizado, no inventa un flujo de verificación que no
  existe.
- **Fecha relativa en publicaciones ("hace 2h", "3d")**: comparado con
  cualquier app grande, ningún post mostraba fecha/hora en absoluto — ni
  siquiera se decodificaba `created_at` en el modelo `Post` de ninguna
  plataforma. Añadido `createdAt` a `Post`/`Post.swift` y una función
  `relativeTime()` en `HomeScreen.kt`/`HomeView.swift` que la formatea
  (ahora/min/h/d/sem). **Android: COMPILADO OK, instalado y relanzado sin
  FATAL en el emulador real.** iOS con `ISO8601DateFormatter`, sin
  verificación de compilador real.
- **"Tus chats" ordenado por actividad reciente**: comparado con cualquier
  app de mensajería (WhatsApp/Instagram DMs siempre muestran el chat más
  reciente arriba), la lista se quedaba en el orden por defecto de la base
  de datos — un mensaje nuevo en un chat antiguo no lo subía al principio.
  Añadido `lastActivity` a `ChatListEntry` (fecha del último mensaje, o de
  creación del chat si todavía no tiene ninguno) y
  `sortedByDescending`/`.sorted` sobre esa fecha. `Chat`/`ChatRow` ahora
  incluye `created_at` para el caso de chat sin mensajes. **Android:
  COMPILADO OK, instalado y relanzado sin FATAL en el emulador real.** iOS
  con el mismo criterio de ordenación por string ISO8601, sin verificación
  de compilador real.
- **Denunciar una publicación directamente**: comparado con cualquier app
  grande, no había forma de denunciar un post concreto — solo existía la
  denuncia global de usuario desde `SafetyToolbar`. `reports.reported_id`
  no tiene columna de `post_id` (no se inventa una nueva), así que se
  reutiliza `ReportSheet` ya construido, denunciando al autor con el id
  del post en los detalles para que moderación sepa cuál. Añadido botón
  "⋯" en `PostCard` (`HomeScreen.kt`/`HomeView.swift`) que abre
  `ReportSheet` con `reportedId = post.authorId`, y un nuevo parámetro
  `initialDetails` en ambos `ReportSheet`. **Android: COMPILADO OK,
  instalado y relanzado sin FATAL en el emulador real.** iOS reutilizando
  el `ReportSheet` ya existente (init ampliado con `initialDetails`,
  cambio mínimo sobre código ya en producción), sin verificación de
  compilador real.
- **Pull-to-refresh en Home y Match**: comparado con Instagram/Twitter/
  Facebook, ninguna pantalla de la app tenía este gesto básico esperado en
  cualquier app social — solo se podía recargar reabriendo la pestaña.
  Añadido con `PullToRefreshContainer`/`rememberPullToRefreshState`
  (material3 1.2.x, `@ExperimentalMaterial3Api`) en `HomeScreen.kt`/
  `MatchScreen.kt`, y `.refreshable {}` nativo de SwiftUI en `HomeView.swift`/
  `MatchView.swift`. **Android: COMPILADO OK (verificando la API
  experimental de pull-to-refresh contra el compilador real, sin
  precedente previo en el proyecto), instalado y relanzado sin FATAL en el
  emulador real.** iOS con `.refreshable`, API nativa documentada, sin
  verificación de compilador real.
- **Borrar el propio comentario**: comparado con cualquier app grande, no
  había forma de borrar un comentario propio — `comments_delete_own`
  (0008_comments.sql) ya lo permitía a nivel de RLS, solo faltaba el
  botón. Añadido `deleteComment()` a `CommentsViewModel.kt`/`.swift` (solo
  visible en comentarios propios, comparando `author_id`/`authorId` con el
  usuario actual) y `commentRemoved()` a `HomeViewModel.kt`/`.swift` para
  mantener `posts.comment_count` sincronizado en el feed sin recargar
  todo. **Android: COMPILADO OK, instalado y relanzado sin FATAL en el
  emulador real.** iOS con el mismo patrón, sin verificación de compilador
  real.
- **Quitar like (toggle real) — bug real, no solo hueco de feature**:
  comparado con cualquier app grande, `like()` (ambas plataformas) era un
  botón de un solo sentido — incrementaba el contador local cada vez que
  se tocaba, PARA SIEMPRE, sin saber si el post ya estaba likeado, mientras
  la tabla `likes` (constraint `unique(post_id, user_id)`) se quedaba en
  una sola fila real. El corazón nunca reflejaba el estado real, y tocarlo
  varias veces desincronizaba el contador visual del real. Añadidos
  `likedPostIds`/`likedPostIDs` (cargados en `load()`, mismo patrón que
  `savedPostIds`) y `toggleLike()` reemplazando a `like()` — inserta o
  borra según el estado real, corazón lleno/vacío
  (`❤`/`🤍` en Android, `heart.fill`/`heart` + color rojo en iOS). **Android:
  COMPILADO OK, instalado y relanzado sin FATAL en el emulador real.** iOS
  con el mismo patrón ya usado en `toggleSave()`, sin verificación de
  compilador real.
- **Editar perfil (nombre/bio/color de avatar)**: comparado con cualquier
  app grande, no había forma de editar los campos centrales del perfil en
  ningún sitio, en ninguna plataforma — solo las 15 secciones (trabajo,
  música...) eran editables, nunca el nombre, la bio ni el color del
  avatar. Añadido `updateBasicInfo()` a `PerfilViewModel.kt`/`.swift` +
  `EditProfileSheet.kt`/`EditProfileView.swift` (nombre, bio, y selector
  de 6 colores para `avatar_config.colorSeed`, que ya usa
  `PlaceholderAvatarProvider`/`AvatarView`). Sin selector de foto real a
  propósito: la generación de avatar 3D sigue sin onboarding construido
  (selfie/consentimiento), y fingir un selector de foto que no alimenta
  nada real sería peor que no tenerlo. **Android: COMPILADO OK, instalado
  y relanzado sin FATAL en el emulador real.** iOS con
  `Color(hex:)`/`TextField`, reutilizando la extensión ya existente en
  `PlaceholderAvatarProvider.swift` (privada de ámbito de archivo, sin
  conflicto real), sin verificación de compilador real.
- **Buscador de personas — comparado explícitamente contra Instagram/
  TikTok/Snapchat**: las tres tienen buscador por nombre; SOCIAL no tenía
  NINGUNA forma de encontrar a alguien salvo la cámara de proximidad (solo
  gente físicamente cerca) o la cuadrícula de Match (candidatos aleatorios,
  sin control del usuario) — un hueco básico de descubrimiento. Añadido
  `SearchViewModel.kt`/`.swift` + `SearchScreen.kt`/`SearchView.swift`:
  `ilike` sobre `display_name` (`profiles_select_public` ya permite leer
  cualquier perfil), con debounce de 300ms y el mismo filtro de bloqueados
  ya aplicado en Match/Home. Entrada nueva "🔍 Buscar" en `HomeScreen.kt` y
  el icono de lupa nativo de `.searchable()` en `HomeView.swift`.
  **Android: COMPILADO OK (verificando `ilike` contra el compilador real,
  sin precedente previo en el proyecto), instalado y relanzado sin FATAL en
  el emulador real.** iOS con `.ilike(_:pattern:)`/`.searchable()`, API
  documentada de supabase-swift/SwiftUI, sin verificación de compilador
  real (límite de plataforma).
- **Fotos en el chat — primera pieza de "chat multimedia"**: `messages`
  solo tenía `body text`, el chat solo soportaba texto — documentado toda
  la sesión como bloqueado por Storage (ya no lo está). Añadido
  `0016_message_media.sql`: columna `media_url` opcional + constraint
  `messages_body_or_media` (`body is not null or media_url is not null` —
  un mensaje necesita al menos uno de los dos, nunca ninguno). Cableado
  selector de foto (📷) junto al campo de texto en `ChatScreen.kt`/`ChatView.swift`,
  `ChatViewModel.sendPhoto()` sube con `StorageUploader` e inserta el
  mensaje, y las burbujas renderizan la imagen real si `media_url` existe
  en vez de una burbuja de texto vacía. Voz/reacciones/read receipts siguen
  pendientes — necesitan grabación de audio nativa y más decisiones de
  diseño, no solo Storage, así que no se han tocado en esta pasada.
  **Android: COMPILADO OK, instalado y relanzado sin FATAL en el emulador
  real.** iOS con `PhotosPicker`/`AsyncImage`, APIs nativas de SwiftUI, sin
  verificación de compilador real (límite de plataforma).
- **HISTORIAS — el hueco documentado como "grande" toda la sesión, cerrado
  de verdad**: el esquema y RLS ya estaban completos desde 0001/0002
  (`expires_at default now()+24h`, `stories_select using (expires_at >
  now())` ya filtra caducadas a nivel de base de datos) — el bloqueo
  entero era la falta de cliente, que dependía de Storage (ver arriba).
  Añadidos `StoriesViewModel.kt`/`.swift` (carga agrupada por autor, sube
  con `StorageUploader`) y `StoriesBar.kt`/`.swift` (fila de círculos en
  la parte superior de Home, burbuja "+" para subir, visor a pantalla
  completa con tap-to-advance tipo Instagram/WhatsApp Status — patrón
  simple a propósito, sin gestos/animaciones complejas sin verificar).
  Wireado en `HomeScreen.kt`/`HomeView.swift`. **Android: COMPILADO OK
  (incluye `Dialog(usePlatformDefaultWidth = false)` para que el visor
  ocupe la pantalla entera en vez del tamaño del item de LazyRow),
  instalado y relanzado sin FATAL en el emulador real.** iOS con
  `.fullScreenCover(item:)`/`PhotosPicker`, APIs nativas de SwiftUI, sin
  verificación de compilador real (límite de plataforma).
- **SUPABASE STORAGE — segundo hueco raíz más grave, cerrado**: no había
  ninguna integración de Storage en ningún sitio del proyecto. Se confirmó
  que sí hay red real en este entorno (ver "Estado real por plataforma"
  arriba) — el bloqueo era solo no tener la dependencia. Añadidos:
  `0015_storage.sql` (bucket público `media`, RLS de Storage con
  convención de carpeta por usuario `{user_id}/archivo`, patrón oficial de
  Supabase — solo se puede subir/editar/borrar dentro de la propia
  carpeta, lectura pública para todos); `storage-kt` añadido a
  `build.gradle.kts` y `install(Storage)` en `SupabaseManager.kt`;
  `StorageUploader.kt`/`.swift` (sube bytes, devuelve URL pública real).
  Conectado al compositor de publicaciones de esta misma sesión: selector
  de imagen nativo (`ActivityResultContracts.GetContent`/`PhotosPicker`),
  subida real antes del insert, y `PostCard` en `HomeScreen.kt`/`HomeView.swift`
  ahora renderiza la foto real con Coil/`AsyncImage` si `media_url` existe
  (antes esa caja era decorativa para TODOS los posts, con o sin imagen).
  **Android: COMPILADO OK (sin `--offline`, verificando de verdad contra
  el compilador real toda la API de Storage:
  `storage.from("media").upload(path, bytes)`/`.publicUrl(path)`),
  instalado y relanzado sin FATAL en el emulador real.** iOS con
  `client.storage.from(_:).upload(path:data:)`/`.getPublicURL(path:)` y
  `PhotosPicker`, APIs documentadas de supabase-swift/SwiftUI, sin
  verificación de compilador real (límite de plataforma).
  **Todavía no aplicado a Historias/avatar 3D/chat multimedia** — esta
  pasada solo cierra fotos de posts, que es lo que estaba más cerca de
  terminarse (el compositor ya existía). Historias necesitaría además el
  flujo de expiración 24h; avatar necesitaría además construir el
  onboarding de selfie/consentimiento que sigue sin UI; chat multimedia
  necesitaría además grabación de audio. El propio Storage ya no es el
  bloqueo para ninguno de los tres — quedan como trabajo real pendiente,
  no como huecos de infraestructura.
- **REGISTRO/LOGIN — el hueco raíz más grave de toda la sesión, cerrado**:
  hasta ahora no existía NINGÚN flujo de autenticación en ninguna
  plataforma — `MainActivity`/`SocialApp.swift` mostraban `RootTabView`
  siempre, sin comprobar sesión. Sin esto, cualquiera que abriera la app
  entraba directo sin cuenta, y todo lo construido esta sesión (chat,
  posts, follow, duelos...) era inalcanzable para un usuario real. Añadido
  `AuthViewModel.kt`/`.swift` + `AuthScreen.kt`/`AuthView.swift`
  (registro/login con email+contraseña, `display_name` real que llega a
  `handle_new_user`) y `AppRoot.kt`/`AppRootView.swift` como punto de
  entrada reactivo (`sessionStatus`/`authStateChanges`): sin sesión →
  AuthScreen, con sesión → RootTabView, sin tener que matar el proceso si
  la sesión cambia. Botón real "Cerrar sesión" nuevo en Ajustes en ambas
  plataformas (antes no existía ninguna pantalla de login a la que volver,
  así que no tenía sentido).
  **Verificación de edad real, no un checkbox**: `legal/privacy_policy_es.md`
  marcaba esto como el riesgo más grave posible de la app. Se pide fecha de
  nacimiento real; si da menos de 18 años, `signUp` NUNCA se llama (no es
  un aviso ignorable) — verificado en vivo en el emulador con una fecha de
  2015 bloqueando la creación de cuenta antes de cualquier llamada de red.
  Documentado honestamente en la política de privacidad que esto es
  autodeclarado, no verificación KYC contra documento de identidad (que
  sigue pendiente si se quiere lanzar a gran escala).
  **Android: COMPILADO OK — esto verificó de verdad contra el compilador
  real toda la superficie de la API de Auth que se había estado asumiendo
  (`signUpWith(Email)`, `signInWith(Email)`, `sessionStatus`,
  `SessionStatus.Authenticated/NotAuthenticated/LoadingFromStorage/NetworkError`),
  instalado y VERIFICADO VISUALMENTE de extremo a extremo en el emulador
  real** (capturas reales: pantalla de registro al abrir la app en vez de
  entrar directo, y bloqueo de edad funcionando). iOS con
  `client.auth.signUp/signIn/authStateChanges`, API documentada de
  supabase-swift 2.x, sin verificación de compilador real (límite de
  plataforma).
- **"Tus publicaciones" — cierra un subelemento del hueco Reels/Pubs./En
  directo gracias al compositor de arriba**: `PerfilView.swift` tenía este
  botón vacío (`{}`), documentado junto a Reels/Pubs. de socials/En directo
  como bloqueado por Storage — ya no es cierto para el caso de texto, con
  `NewPostView` ya real. Android nunca tuvo esta rejilla de 6 subsecciones
  de iOS en absoluto. Añadido `MyPostsScreen.kt`/`MyPostsView.swift`: lista
  las propias publicaciones con borrado real (`posts_write_own` ya era
  `for all` en RLS, solo faltaba el botón — swipe-to-delete en iOS, botón
  "Borrar" en Android). Entrada nueva en la rejilla de iOS y como cuarto
  botón "🖼 Tus publicaciones" junto a Ajustes/Tus duelos/Tus chats en
  Android. **Android: COMPILADO OK, instalado y relanzado sin FATAL en el
  emulador real.** iOS con `.swipeActions`, API nativa de SwiftUI.
- **Crear publicaciones — otro hueco grande cerrado sin necesitar
  Storage**: hallazgo real, el más grande de esta ronda — se podía dar
  like, comentar, guardar y compartir publicaciones ajenas, pero no existía
  NINGUNA forma de crear una publicación propia en ninguna plataforma. A
  diferencia de `stories.media_url` (`not null` — por eso Historias sigue
  bloqueada), `posts.media_url` es opcional (0001_schema.sql): una
  publicación solo de texto es válida a nivel de esquema y RLS
  (`posts_write_own`) sin Supabase Storage. Añadido
  `NewPostViewModel.kt`/`.swift` + `NewPostSheet.kt`/`NewPostView.swift`
  (caption + checkbox `is_social_only`), con un FAB "+" nuevo en
  `HomeScreen.kt` (sin icono "Add" en el set base de iconos del proyecto —
  mismo límite ya resuelto con texto en la pestaña Social, texto "+" en vez
  de icono) y un botón de toolbar en `HomeView.swift`. **Android:
  COMPILADO OK, instalado y VERIFICADO VISUALMENTE de extremo a extremo en
  el emulador real** (captura real del compositor abierto con campo de
  texto, checkbox y botón "Publicar", sin FATAL). iOS con
  `TextField(axis: .vertical)`/`Toggle`, APIs reales de SwiftUI, sin aviso
  de honestidad necesario.
- Ronda de verificación visual larga por las 5 pestañas tras la ráfaga de
  cambios de hoy (chat list, follow/unfollow, contadores, badge, nombres de
  oponente): Home y Match muestran el error de red esperado contra
  credenciales placeholder (sin crash); Social renderiza el patrón de
  cámara del emulador con normalidad; Perfil muestra avatar, contadores en
  0 y las tres entradas nuevas ("Tus duelos"/"Tus chats"/Ajustes) con
  navegación real verificada extremo a extremo. Avisos aparece en blanco
  sin mensaje de error — **no es un bug nuevo**: `AvisosViewModel.start()`/
  `NotificationsBadgeViewModel.start()` cortan pronto si
  `currentUserOrNull()?.id` es null, y no hay sesión real porque no existe
  ningún flujo de login/registro en la app (mismo hueco raíz ya
  extensamente documentado) — a diferencia de Home/Match, que consultan
  sin requerir sesión y sí disparan el error de red. Sin FATAL en ningún
  tab durante toda la ronda.
- **Realtime en "Tus chats" — refuerzo del inbox recién construido**: sin
  esto, un chat nuevo (social recién aceptado mientras la lista estaba
  abierta) no aparecía hasta salir y volver a entrar — mismo criterio "en
  vivo, no solo al abrir" ya aplicado a Avisos/Chat. Añadidos
  `start()`/`stop()` a `ChatListViewModel.kt`/`.swift` con dos
  suscripciones a `chats` (`user_a_id`/`user_b_id` por separado, porque
  `postgresChangeFlow`/`postgresChange` filtran por una sola columna a la
  vez — mismo límite ya documentado en `NotificationsBadgeViewModel`).
  **Android: COMPILADO OK, instalado y relanzado sin FATAL en el emulador
  real.** iOS con el mismo patrón `for await` ya usado en
  `NotificationsBadgeViewModel.swift`, sin verificación de compilador real.
- Ciclo de verificación (invocación `/loop` fresca): comprobado que
  `EventModeBanner`/`EventModeViewModel` (Modo Evento) SÍ está cableado de
  verdad en `SocialCameraScreen.kt` (`checkForNearbyEvent` en un
  `LaunchedEffect` con `LocationManager` real + `EventModeBanner(viewModel
  = eventMode)` renderizado) — no era el mismo patrón de "construido pero
  nunca llamado" que se encontró antes con Avatar/onboarding. `assembleDebug
  --offline` limpio, confirmando que todo lo añadido en esta sesión sigue
  compilando junto sin conflictos.
- **Lista de chats (inbox) — el hallazgo más grande de esta pasada**: no
  existía NINGUNA pantalla de lista de chats en toda la app, en ninguna
  plataforma — la única forma de entrar a un chat era un `chatId` puntual
  llegado desde una notificación de social aceptado. Una vez se salía de
  ese chat, no había forma de volver a encontrarlo salvo esperar otra
  notificación nueva, lo cual en la práctica hacía el chat casi
  inalcanzable. Añadido `ChatListViewModel.kt`/`.swift` +
  `ChatListScreen.kt`/`ChatListView.swift`: consulta `chats` con
  `filter { or { eq(user_a_id); eq(user_b_id) } }` (mismo patrón ya
  verificado en `DuelHistoryViewModel`), resuelve el nombre del otro
  participante y el último mensaje con una consulta por chat cada uno (sin
  join embebido, mismo criterio ya aplicado al nombre de oponente de
  duelos — `chats`/`messages` no tienen columna de "último mensaje").
  Punto de entrada nuevo "💬 Tus chats" en `PerfilScreen.kt`/`PerfilView.swift`,
  junto a "Tus duelos"/"Ajustes". **Android: COMPILADO OK, instalado y
  VERIFICADO VISUALMENTE de extremo a extremo en el emulador real**
  (captura real navegando Perfil → Tus chats → estado vacío correcto, sin
  FATAL). iOS con `.navigationDestination(isPresented:)` en vez de
  `(item:)` (la variante `(item:)` es exclusiva de iOS 17+, no compila
  contra el deployment target real del proyecto, iOS 16) y los mismos
  métodos `.select/.eq/.order/.limit.single()` ya usados en el resto del
  proyecto — sin verificación de compilador real (límite de plataforma).
- **Nombre del oponente también en `DuelResultScreen`/`View` — misma
  extensión que el historial, mismo hallazgo**: al resolver el nombre del
  oponente en `DuelHistoryViewModel` (ver justo abajo), se comprobó que el
  visor de resultado individual (accesible también desde notificaciones)
  tenía exactamente el mismo hueco — nunca mostraba contra quién fue el
  duelo. Mismo patrón: cargar `duels`, calcular cuál de
  `initiator_id`/`opponent_id` es "el otro" comparando con el usuario
  actual, y una consulta de `display_name` por ese id. **Android:
  COMPILADO OK, instalado y relanzado sin FATAL en el emulador real.** iOS
  con el mismo patrón `.select(columns:).eq().single()`, sin verificación
  de compilador real.
- **Nombre del oponente en el historial de duelos — resuelve una
  limitación documentada, no un bug**: `DuelHistoryViewModel.kt`/`.swift`
  mostraban solo fecha + delta a propósito, porque `duels` tiene DOS
  columnas que referencian `profiles` (`initiator_id`/`opponent_id`) y
  desambiguar el nombre exacto de la foreign key para un join embebido sin
  poder probarlo contra un Postgres real habría sido adivinar. Resuelto sin
  necesitar esa FK: una consulta de `display_name` por id del "otro"
  participante tras cargar la lista — mismo patrón ya seguro usado en
  `BlockedUsersViewModel`. Ahora cada fila del historial muestra el nombre
  real en vez de solo la fecha. **Android: COMPILADO OK, instalado y
  relanzado sin FATAL en el emulador real.** iOS con el mismo patrón
  `.select(columns:).eq().single()` ya usado en el resto del proyecto, sin
  verificación de compilador real (límite de plataforma).
- **Contadores de perfil (publicaciones/seguidores/seguidos/socials) en
  `PerfilScreen.kt` (Android) — paridad con iOS, que ya los tenía**:
  hallazgo real — `PerfilViewModel.swift.loadCounters()` ya calculaba los
  cuatro (bug ya corregido en una pasada anterior de esta sesión), pero
  `PerfilViewModel.kt` nunca tuvo ninguno — Android nunca mostró ninguna
  cifra de publicaciones/seguidores/seguidos/socials, ni siquiera en 0
  fijo. Al añadir `followersCount`/`followingCount` para el follow/unfollow
  de esta misma pasada, se amplió a los cuatro para cerrar la paridad
  completa de una vez: `postCount` (`posts` por `author_id`),
  `followersCount`/`followingCount` (`follows`), `socialCount` (`socials`
  con `status = 'accepted'`, sumando `requester_id`+`addressee_id` igual
  que hace iOS). Línea "N publicaciones · N seguidores · N siguiendo · N
  socials" bajo el nombre en `PerfilScreen.kt`. **COMPILADO OK, instalado y
  relanzado sin FATAL en el emulador real.**
- **Match → abrir perfil completo — feature nueva, cierra el hueco que
  dejaba inalcanzable el "Seguir" recién añadido**: hallazgo real,
  encontrado inmediatamente después de construir el follow/unfollow de
  arriba — la cuadrícula de `MatchScreen.kt`/`MatchView.swift` no llevaba a
  ningún sitio salvo el botón de pedir compatibilidad; no había forma de
  abrir el visor de perfil completo de un candidato desde Match. Sin esto,
  el nuevo botón "Seguir" de `ProfileViewerScreen`/`View` solo era
  alcanzable desde una notificación, no desde el flujo natural de explorar
  candidatos. Añadida navegación real: `MatchScreen.kt` con `clickable` en
  la tarjeta + callback `onOpenProfile` cableado en `RootTabView.kt` a la
  ruta `profile/{profileId}` ya existente; `MatchView.swift` con
  `NavigationLink` envolviendo `MatchCell` (aprovecha el `NavigationStack`
  propio de `MatchView`). **Android: COMPILADO OK, instalado y relanzado
  sin FATAL en el emulador real**. iOS con `NavigationLink`/`UUID`, API
  nativa de SwiftUI, sin aviso de honestidad necesario.
- **Seguir/dejar de seguir directo desde un perfil — feature completa,
  nueva esta pasada**: hallazgo real — `FollowManager` (ambas plataformas)
  solo tenía `follow()`, nunca `unfollow()`, y la única forma de seguir a
  alguien en toda la app era el botón "Seguir de vuelta" de una
  notificación (`AvisosScreen.kt`/`.swift`) — `ProfileViewerScreen`/`View`
  no tenía ningún botón de seguir en absoluto, a pesar de ser la pantalla
  natural para eso. `follows_select` (0002_rls.sql) es pública
  (`using (true)`), así que se puede consultar el estado real "¿le sigo
  ya?" sin necesitar una función RPC nueva. Añadido `unfollow()` +
  `isFollowing()` a `FollowManager.kt`/`.swift`, y un botón real
  Seguir/Siguiendo en `ProfileViewerScreen.kt`/`ProfileViewerView.swift`
  (oculto cuando el perfil visitado es el propio). **Android: COMPILADO OK
  (assembleDebug limpio, verificando `.delete { filter {...} }` y
  `.select { filter {...} }` con doble `eq` — sin precedente previo exacto,
  comprobado en vez de asumido), instalado y relanzado sin FATAL en el
  emulador real**. iOS razonado sobre los mismos métodos `.delete()/.eq()`
  ya usados en `BlockedUsersViewModel.swift`, sin verificación de
  compilador real (límite de plataforma).
- **Badge de no leídas en la pestaña Avisos — feature completa, nueva esta
  pasada**: hallazgo real — `notifications.read_at` ya distingue leído/no
  leído desde el esquema original y `AvisosViewModel.markRead()` ya lo
  actualiza, pero ninguna plataforma mostraba nunca si había avisos nuevos
  sin entrar a mirar la pestaña. Añadido
  `NotificationsBadgeViewModel.kt`/`.swift` con suscripción Realtime (mismo
  patrón ya compiler-verificado en `ChatViewModel.kt`/`AvisosViewModel.kt`:
  `postgresChangeFlow<Insert/Update>`, no sondeo) — Android muestra un
  `BadgedBox`/`Badge` de Material3 sobre el icono de la pestaña, iOS usa
  `.badge(count)` nativo de SwiftUI (API real de iOS 15+, sin aviso de
  honestidad necesario). **Android: COMPILADO OK (assembleDebug limpio tras
  corregir un import de `launchIn` que faltaba), instalado y relanzado sin
  FATAL en el emulador real**. iOS razonado sobre los mismos tipos
  `InsertAction`/`UpdateAction`/`postgresChange` ya usados en
  `AvisosViewModel.swift`, sin verificación de compilador real (límite de
  plataforma).
- **`handle_new_user` — trigger que crea `profiles` al registrarse, pieza
  de esquema del hueco raíz "no existe flujo de registro"**: confirmado en
  una pasada anterior que no había ningún trigger `on_auth_user_created` ni
  ningún `insert` a `profiles` en ninguna plataforma — cualquier alta real
  en Supabase Auth se quedaría sin fila en `profiles`, y todo lo que tiene
  FK a esa tabla (posts, chats, likes, etc.) fallaría. Añadido
  `0014_handle_new_user.sql`: función `private.handle_new_user()`
  (`security definer`, `search_path` vacío, mismo patrón que
  `private.is_blocked`) + trigger `after insert on auth.users`, que crea la
  fila con `display_name` derivado de `raw_user_meta_data->>'display_name'`
  (si un futuro signUp lo manda) o si no del prefijo del email, o si no
  `'Nuevo usuario'` — `display_name` es `not null` en 0001_schema.sql. No
  resuelve el onboarding completo (la UI de selfie/consentimiento/avatar
  sigue sin existir en ninguna plataforma, sigue documentado abajo), pero
  cierra la parte de la base de datos que rompería cualquier flujo de
  registro que se construya después. Sin cambios de cliente — build de
  Android verificado sin errores tras el cambio (SQL puro).
- **Extendido el bloqueo real de RLS al chat — el más importante de los tres**:
  mismo hallazgo que 0011/0012 pero en `messages_insert` (0002_rls.sql), que
  solo comprobaba que el remitente fuera parte del chat, nunca `blocks`. Una
  vez existía un chat, bloquear a la otra persona no impedía que siguiera
  escribiendo. Corregido en `0013_block_enforcement_chat.sql` calculando la
  "otra parte" del chat (`case when chats.user_a_id = auth.uid() then
  user_b_id else user_a_id end`) y comprobándola con
  `private.is_blocked(a,b)`. De los tres fixes de bloqueo (socials/follows/
  compat_requests, likes/comments, chat), este es el más importante: es el
  canal de comunicación más directo de una app que facilita encuentros
  físicos con desconocidos. Sin cambios de cliente — build de Android sin
  errores tras el cambio (SQL puro).
- **Extendido el bloqueo real de RLS a likes/comments**: mismo hallazgo que
  `0011_block_enforcement.sql` pero en `likes_insert_own`/
  `comments_insert_own` — un usuario bloqueado podía seguir dando like o
  comentando en los posts de quien lo bloqueó, e incluso generarle una
  notificación real (los triggers `notify_new_like`/`notify_new_comment` no
  distinguían bloqueo). Corregido en `0012_block_enforcement_posts.sql`
  reutilizando `private.is_blocked(a,b)`, comprobando contra el
  `author_id` del post referenciado por `post_id`. Bloquear a alguien
  ahora detiene también sus interacciones sobre tu contenido, no solo el
  envío de socials/follows/compat_requests. Sin cambios de cliente.
- **Bloqueo aplicado de verdad a nivel de RLS, no solo ocultado en UI —
  hallazgo de seguridad real encontrado al revisar el fix anterior**:
  `socials_insert`/`follows_write_own`/`compat_requests_insert`
  (0002_rls.sql) solo comprobaban `requester_id/follower_id = auth.uid()`,
  nunca `blocks` — un cliente modificado podía seguir mandando un social/
  follow/compat_request directamente a (o desde) alguien bloqueado,
  saltándose por completo el filtro de UI de la pasada anterior. RLS es el
  límite de confianza real de este proyecto (ver `security_checklist.md`),
  no la UI. Corregido con `0011_block_enforcement.sql`: función
  `private.is_blocked(a,b)` (mismo patrón que `has_accepted_social` —
  security definer, `search_path=''`, revoke/grant) que comprueba bloqueo
  en cualquier dirección, añadida al `with check` de las 3 políticas. No
  se tocó `using` a propósito: seguir pudiendo borrar/editar una relación
  ya existente tras un bloqueo posterior (p. ej. dejar de seguir) debe
  seguir funcionando. Sin cambios de cliente — el `try/catch` que ya rodea
  estos inserts absorbe el rechazo con el mismo mensaje genérico de
  siempre. Sintaxis verificada por balance de paréntesis/`$$`, no
  ejecutable contra Postgres real en este entorno.
- **Fallo de privacidad real: bloquear a alguien no lo ocultaba de Match/Home**.
  El fix de invisible/self-exclusión de esta sesión nunca cubrió `blocks` —
  a quien bloqueabas seguía apareciendo en la cuadrícula de Match y en
  Recomendados de Home, en ambas plataformas. Corregido en
  `MatchViewModel.kt`/`HomeViewModel.kt`/`MatchViewModel.swift`/
  `HomeViewModel.swift`: se carga `blocks` (solo la dirección que RLS deja
  ver — "a quién he bloqueado yo"; ver quién me bloqueó a mí no es posible
  por diseño de RLS, un límite de privacidad correcto, no un hueco) y se
  excluyen esos perfiles de los candidatos. **COMPILADO OK en Android**,
  instalado y verificado sin crash en el emulador navegando a Home.
- **Hallazgo grande: Android nunca renderizaba ningún avatar, en ningún
  sitio, a pesar de consultar `avatar_url` en varias pantallas**: el
  modelo `Profile.kt` ni siquiera tenía el campo `avatar_config` (existe en
  0001_schema.sql desde el principio), así que aunque se hubiera querido
  pintar un avatar, faltaba el dato. Añadido el campo al modelo, incluido
  en las columnas seleccionadas donde faltaba (`HomeViewModel.kt`,
  `MatchViewModel.kt`, `ProfileViewerScreen.kt`), y creado
  `avatar/AvatarView.kt` — mismo placeholder exacto que
  `PlaceholderAvatarProvider.swift` (círculo con degradado + icono de
  persona, mismo color por defecto `8B5CF6`), cableado en
  `HomeScreen.kt`/`MatchScreen.kt`/`PerfilScreen.kt`/`ProfileViewerScreen.kt`.
  De paso se encontró que `ProfileViewerView.swift` (iOS) TAMBIÉN se había
  quedado sin avatar — a diferencia de `PerfilView`/`HomeView`/`MatchView`,
  nunca llamaba a `ActiveAvatarProvider` — corregido también. **Compilado,
  instalado y verificado visualmente en el emulador**: capturas reales
  mostrando el círculo morado con icono de persona en la cabecera de
  Perfil, sin crash.
- **"Fights" (historial de duelos) — antes un botón vacío `{}` en iOS,
  Android ni siquiera tenía la rejilla de subsecciones**: se intentó
  construir Historias primero, pero `stories.media_url` es `not null` y no
  hay Storage real (mismo bloqueo que el chat multimedia) — habría sido
  fingir datos falsos, así que se pivotó a "Fights", la única subsección
  que no depende de fotos/vídeo (usa `duels`, ya con datos reales de
  verdad). `DuelHistoryViewModel.kt`/`DuelHistoryScreen.kt` (Android,
  **compilado**: confirmó `filter { or { eq(...); eq(...) } }` como sintaxis
  real de supabase-kt, sin precedente previo en el código — verificado, no
  asumido) y `DuelHistoryViewModel.swift`/`DuelHistoryView.swift` (iOS, con
  aviso de honestidad sobre `.or("col.eq.val,...")`). Lista + fecha + delta
  por duelo, sin nombre de oponente a propósito (desambiguar cuál de las
  dos FK de `duels` a `profiles` usar sin Postgres real sería adivinar).
  Toca un duelo para abrir `DuelResultScreen`/`DuelResultView`, que ya
  existía pero solo era alcanzable desde notificaciones. Instalado y
  verificado visualmente en el emulador (capturas reales navegando
  Perfil → "⚡ Tus duelos" → lista vacía correcta, sin crash).
- Join real `event_attendees + profiles` en Modo Evento (antes placeholder).
- `growth_strategy.md`: estrategia de adopción honesta (cuña = Modo Evento,
  densidad efectiva como métrica, no usuarios totales).
- `analytics_events` (migración 0005) + `event_density()`: analítica mínima
  auto-alojada en Supabase, sin SDKs de terceros de pago (coherente con la
  preferencia del usuario por herramientas open-source/gratuitas).
- `AnalyticsManager.kt` instrumentado en app_open/tab_view/invisible_toggled.
- **Comentarios reales en publicaciones (feature completa, no un fix)**:
  `0008_comments.sql` (tabla `comments` + RLS + trigger que sincroniza
  `posts.comment_count` + trigger de notificación `kind='comment'`, mismo
  patrón que 0006/0007) más UI funcional en ambas plataformas —
  `CommentsViewModel.kt`/`CommentsSheet.kt` (Android, **compilado y
  verificado**: `insert(...) { select() }` para pedir de vuelta la fila
  insertada, confirmado con el compilador real, no una suposición) y
  `CommentsViewModel.swift`/`CommentsView.swift` (iOS, con aviso de
  honestidad sobre la cadena `.insert().select().single()` sin verificar).
  Tocar el contador "💬" en el feed abre la hoja de comentarios; publicar
  uno actualiza el contador visible sin recargar el feed entero. Cierra el
  hueco que llevaba varias pasadas en "Pendiente real". Instalado y
  verificado en el emulador real sin crash al navegar a Home.
- **Guardar publicaciones (bookmarks) — feature completa**: `0009_saved_posts.sql`
  (tabla `saved_posts`, privada del usuario — RLS solo permite ver/crear/
  borrar las propias filas, sin trigger de contador porque no hay
  `posts.save_count` en el esquema, a diferencia de like/comment). El icono
  de guardar era puramente decorativo en ambas plataformas (ni siquiera un
  intento de wiring, a diferencia del "like" falso). Añadido `toggleSave()`
  en `HomeViewModel.kt`/`HomeViewModel.swift` con estado optimista +
  persistencia real, y el icono ahora refleja el estado guardado/no
  guardado. **`.delete { filter {...} }` verificado con el compilador real
  de Android** (sin precedente previo en el código, comprobado en vez de
  asumido). Instalado y verificado sin crash navegando a Home.

- **Compartir (share sheet nativo) — feature completa, resuelta en una
  pasada posterior**: el icono de compartir era puramente decorativo en
  ambas plataformas (Android ni siquiera lo tenía — el `PostCard` de
  `HomeScreen.kt` nunca llegó a incluir un tercer icono como iOS). Resuelto
  con el share sheet nativo de cada plataforma en vez de infraestructura
  propia (no hace falta tabla ni backend para esto): `Intent.ACTION_SEND` +
  `Intent.createChooser` en Android (COMPILADO OK, verificado sin crash en
  el emulador tras instalar) y `ShareLink` de SwiftUI (API real de iOS 16+,
  coincide con el `deploymentTarget` del proyecto — no es una suposición,
  es un framework de Apple documentado) en iOS.

- **Gestión de bloqueados (ver/desbloquear) — feature completa, nueva
  esta pasada**: hallazgo real — `SafetyManager.block()`/`.swift` existía
  desde antes de esta sesión y `blocks_delete_own` (0003_safety.sql) ya
  permitía desbloquear a nivel de RLS, pero ninguna plataforma tenía
  pantalla para ver a quién habías bloqueado ni botón para desbloquear —
  un bloqueo era, en la práctica, permanente. Añadido
  `BlockedUsersViewModel.kt`/`.swift` + `BlockedUsersScreen.kt`/
  `BlockedUsersView.swift`, con entrada nueva "Usuarios bloqueados" en
  Ajustes en ambas plataformas. Sin `isIn`/filtro de pertenencia por lista
  verificado en el resto del código — mismo patrón que Match/HomeViewModel
  (filtrado en cliente): una consulta por id bloqueado, listas pequeñas
  por naturaleza. **Android: COMPILADO OK (assembleDebug limpio)**. iOS
  razonado sobre las mismas APIs `.from/.select/.eq/.delete` ya
  compiler-verificadas en Android, sin verificación de compilador real
  (límite de plataforma).

## "Historias, comentar, enviar, guardar" — RESUELTO POR COMPLETO
Las cuatro piezas están cerradas: comentar, guardar y compartir (pasadas
anteriores) + **Historias** (esta pasada), construida sobre el Storage
real añadido esta sesión. `StoriesViewModel.kt`/`.swift` +
`StoriesBar.kt`/`.swift`: barra horizontal en la parte superior de Home,
selector de imagen del sistema (mismo patrón que el compositor de posts,
no cámara dedicada — decisión consciente, no un hueco), visor a pantalla
completa con `Dialog`/toque-para-avanzar. La expiración a 24h es real y ya
funcionaba desde el esquema original sin código de cliente adicional:
`stories_select` (0002_rls.sql) usa `using (expires_at > now())`, así que
Postgres nunca devuelve una historia caducada — no hace falta ninguna
lógica de "ocultar" en el cliente. **Android: COMPILADO OK, instalado y
relanzado sin FATAL en el emulador real, `StoriesBar` cableada en
`HomeScreen.kt`.** iOS con `StoriesBar.swift` cableada en `HomeView.swift`,
mismo patrón, sin verificación de compilador real.

- **Borrado de cuenta — bloqueante legal resuelto**: la política de
  privacidad prometía "borrado completo... desde Ajustes" pero no existía
  ni pantalla de Ajustes ni mecanismo de borrado en ninguna plataforma (ya
  documentado como bloqueante RGPD/CCPA real). Construido de punta a punta:
  `supabase/functions/delete-account/index.ts` (Edge Function con
  service_role, mismo patrón que `duel-ai` — usa `auth.admin.deleteUser`,
  que cascada de verdad hasta `profiles` y todo lo dependiente vía los
  `on delete cascade` ya presentes en 0001_schema.sql; nunca acepta un
  user_id del body, solo borra al usuario autenticado del propio JWT).
  Primera pantalla de Ajustes que ha existido en cualquier plataforma:
  `AccountManager.kt`/`AjustesScreen.kt` (Android, **compilado, instalado y
  verificado visualmente en el emulador** — captura real mostrando "Borrar
  mi cuenta" con confirmación de dos pasos) y
  `AccountManager.swift`/`AjustesView.swift` (iOS, con el aviso de
  honestidad habitual sobre `functions.invoke` sin `options`). Cierra el
  hallazgo más grave de toda la auditoría de esta sesión.

## Verificación disponible (usar siempre antes de dar algo por hecho)
```
export JAVA_HOME="/c/Users/assce/AppData/Local/Programs/Microsoft/jdk-17.0.10.7-hotspot"
export PATH="$JAVA_HOME/bin:$PATH"
cd "C:/Users/assce/Social/Android" && ./gradlew assembleDebug
ADB="/c/Users/assce/AndroidSdk/platform-tools/adb.exe"
$ADB install -r app/build/outputs/apk/debug/app-debug.apk
$ADB shell am start -n com.social.app/.MainActivity
```
Emulador AVD `social_test` (Pixel 5, API 33) — puede seguir vivo entre
sesiones; comprobar con `adb devices` antes de crear uno nuevo.

## Pendiente real (no inventar más alcance sin que aparezca aquí)
- **Notificaciones locales del sistema — RESUELTAS por completo en ambas
  plataformas, incluido el matiz de alcance de iOS** (ver "Última pasada"
  para el detalle).
- **Push verdadero (APNs/FCM) — infraestructura y cliente completos en
  AMBAS plataformas, RONDA 2026-08-25** (ver "Ronda 2026-08-25 (push +
  hallazgo de seguridad crítico)" para el detalle): tabla `device_tokens`
  + RLS, trigger `pg_net` → Edge Function `send-push` (APNs JWT ES256 /
  FCM legacy), y el cliente que faltaba en ambas plataformas
  (`PushTokenManager` en iOS y Android, registra el token con sesión
  real). **Pendiente real de despliegue, no de código**: proyecto Firebase
  real + `app/google-services.json` (Android), clave `.p8` de Apple +
  `APNS_TEAM_ID`/`APNS_KEY_ID` + cuenta Apple Developer de pago (iOS,
  necesaria para el entitlement `aps-environment` en producción — CI usa
  "development" sin equipo real), y los secrets de Supabase
  (`supabase secrets set ...` + `alter database ... set app.settings...`)
  documentados en el propio código. Sin esas credenciales reales, todo el
  código compila y corre pero no envía push de verdad — mismo criterio de
  honestidad que duel-ai/icebreaker-ai.
- **RESUELTO EN ANDROID, COMPILADO Y VERIFICADO** (assembleDebug OK,
  instalado y arrancado en emulador sin crash, PID 16986) — pendiente
  replicar en iOS: el motor UWB ahora intercambia también el
  `profile_id` real de Supabase (autenticado) además del peerId efímero,
  con protocolo de mensaje explícito ("A|.../"C|..."). Los marcadores de
  la cámara ya son tocables cuando se conoce el profileId real, y abren
  una hoja "Enviar social" que llama a `SocialLinkManager.sendSocial`.
  Análisis de seguridad: el servidor sigue validando `requester_id =
  auth.uid()` vía RLS, así que nadie puede enviar un social en nombre de
  otro — el único riesgo es que un cliente modificado mienta sobre SU
  PROPIO profileId (social mal dirigido, no account-takeover), mismo nivel
  de confianza que ya existe en el resto del intercambio Nearby.
- **iOS: REPLICADO esta pasada** — `DiscoveryTokenMessage`/`PeerProximity`
  llevan ahora `profileID` (PeerToken.swift), `SocialProximity.swift`
  guarda `remoteProfileIDs`/`localProfileID` y los propaga, y
  `SocialCameraView.swift` hace tocables los marcadores + hoja
  `SendSocialSheet` llamando a `SocialLinkManager.sendSocial`. SIN
  verificación de compilador real (límite de plataforma, no de esfuerzo) —
  mismo nivel de confianza que el resto de cambios iOS de la sesión.
  El flujo completo "ver a alguien por UWB → tocar → enviar social" está
  ahora implementado (con matices de honestidad) en AMBAS plataformas.
- **RESUELTO (2026-08-24): ya hay un proyecto Supabase real conectado**
  (`local.properties` con URL/clave reales del usuario, proyecto
  `yzxzsaprvtsavkuhqfao`, región eu-west-1). Las 39 migraciones están
  aplicadas en producción (verificado con conexión directa vía pooler,
  `postgres.<ref>@aws-1-eu-west-1.pooler.supabase.com:5432` — el host
  directo `db.<ref>.supabase.co` NO resuelve desde este entorno, IPv6
  only). Registro/login reales probados end-to-end en el emulador con una
  cuenta de prueba creada por SQL directo (bypass del límite de envío de
  email del plan gratis de Supabase, que se agota con 1-2 intentos de
  signup reales). Contraseña de la base de datos NUNCA debe commitearse —
  vive solo en `local.properties` (gitignored) y en la memoria de la
  sesión, no en ningún archivo del repo.
- **RESUELTO (2026-08-24): iOS ya compila de verdad, con un compilador
  real.** `.github/workflows/build.yml` corre en un runner macOS real de
  GitHub Actions en cada `git push` a `main` — `BUILD SUCCESSFUL`
  confirmado, app lanzada en el Simulador de iOS, captura de pantalla
  real subida como artefacto (`AuthView.swift` renderizando
  correctamente). 15 rounds de fallos reales encontrados y corregidos
  para llegar ahí (ver "Ronda 2026-08-24" arriba para el detalle
  completo — el más grave: `.select(columns:)` mal etiquetado, repetido
  en 12 sitios, habría roto la app entera). A partir de ahora, cualquier
  cambio de código Swift SÍ puede (y debe) verificarse empujando a
  `main` y revisando el run de Actions — ya no hace falta razonar por
  analogía sin comprobar. El repositorio es público:
  `github.com/asscervera-gif/social-app`.
- App Store / Play Store submission: fuera del alcance de lo que se puede
  hacer sin un humano con cuenta de desarrollador (ver
  `legal/app_store_submission_checklist.md`).
- **RESUELTO (entrada obsoleta corregida esta pasada)**: el borrado de
  cuenta SÍ existe y está construido de punta a punta en ambas
  plataformas — Edge Function `delete-account` (borra `auth.users`, cascada
  real hasta `profiles` y dependientes, la `service_role` key nunca sale
  del servidor, mismo patrón que `duel-ai`), `AccountManager.kt`/
  `AccountManager.swift` la invocan y hacen `signOut()` local, y
  `AjustesScreen.kt`/`AjustesView.swift` exponen el botón "Borrar mi
  cuenta" con diálogo de confirmación de dos pasos ("¿Borrar tu cuenta?" →
  "Borrar de verdad"). Esta entrada llevaba pasadas sin actualizarse tras
  resolverse — verificado ahora releyendo los 4 archivos implicados, sin
  cambios de código necesarios.
- **`compileSdk`/`targetSdk` = 34 (Android 14) en `build.gradle.kts`** —
  correcto y compila hoy, pero Play Store exige periódicamente targetear
  una API reciente (dentro de ~1 año de la última estable) para nuevas
  subidas/actualizaciones. Dada la fecha actual de este entorno (agosto de
  2026) y que mi conocimiento verificado no cubre con certeza qué exige
  Google Play en esa fecha exacta, y que el SDK local solo tiene las
  plataformas 33/34 descargadas (no se ha intentado traer una más nueva por
  no arriesgar el build ya verificado sin necesidad real todavía — ahora
  que se confirmó que sí hay red en este entorno, sería descargable si
  hiciera falta), esto queda como un chequeo real pendiente
  para quien suba la app: confirmar el requisito de targetSdk vigente en el
  momento real de publicación y actualizar `compileSdk`/`targetSdk` (y
  probar de nuevo) si hace falta. No es una suposición mía de que esté mal
  — es honestidad sobre el límite de lo verificable desde aquí.
- **RESUELTO POR COMPLETO (entrada obsoleta corregida esta pasada)**: voz
  (`VoiceRecorder.kt`, `0019_message_audio.sql`) y reacciones
  (`0018_message_reactions.sql`, `toggleReaction`, barra de 5 emojis en
  `ChatScreen.kt`) también están construidos y verificados — esta entrada
  seguía diciendo "pendientes" desde antes de resolverse. Con esto, las 4
  piezas de "chat funcional con fotos, voz, reacciones, read receipts" del
  prompt original están cerradas en Android; iOS en paridad sin
  verificación de compilador (límite de plataforma, no de alcance).
- Detalle histórico (ya resuelto, contexto): el chat solo soportaba texto —
  "chat funcional con fotos, voz, reacciones, read receipts" pedido en el
  prompt original. Fotos: `0016_message_media.sql` (`messages.media_url`
  opcional + constraint `body is not null or media_url is not null`),
  selector de imagen en `ChatScreen.kt`/`ChatView.swift`. **Read
  receipts (esta pasada)**: `0017_message_read_receipts.sql` —
  `messages.read_at`, mismo patrón que `notifications.read_at`, con
  política `messages_update_read` que solo deja marcar como leídos los
  mensajes AJENOS (nunca los propios, ni siquiera intentándolo). Al abrir
  un chat se marcan como leídos los mensajes del otro
  (`markMessagesRead()`), y el remitente ve "Enviado ✓"/"Leído ✓✓" en vivo
  vía Realtime (suscripción nueva a `UPDATE` en `messages`, además del
  `INSERT` ya existente). **Android: COMPILADO OK (con un fix real:
  `isNull` no existe en el DSL de filtros de este proyecto, sustituido por
  una actualización idempotente sin ese filtro), instalado y relanzado sin
  FATAL en el emulador real.** iOS con el mismo patrón, sin verificación
  de compilador real. Quedan pendientes, cada uno su propio alcance de
  diseño: grabación de audio nativa + reproductor (voz) y UI de
  reacciones — no inventado aquí, documentado como trabajo real futuro.
- **RESUELTO EN AMBAS PLATAFORMAS (entrada obsoleta corregida esta
  pasada)**: Android también tiene ya `onboarding/SelfieConsentScreen.kt` y
  `onboarding/AvatarOnboardingScreen.kt`, disparados desde `AppRoot.kt` vía
  `Dialog` cuando `avatar_config` es nulo — mismo patrón que iOS. Esta
  entrada seguía diciendo "pendiente en Android" desde antes de resolverse.
- Detalle histórico (ya resuelto en iOS, contexto): `SelfieConsentView.swift`/
  `AvatarProvider.generateAvatar()` ya estaban construidos desde antes,
  solo faltaba dispararlos — ahora que el registro real existe
  (`AuthView.swift`), `AppRootView.swift` comprueba tras cada login si
  `profiles.avatar_config` sigue sin configurar y muestra
  `OnboardingAvatarView.swift` (consentimiento → selector de foto →
  `generateAvatar` → guarda `avatar_config`) una sola vez. Sigue usando
  `PlaceholderAvatarProvider` (círculo con color, no un motor 3D real —
  ver aviso de honestidad en `AvatarProvider.swift`, sin cambios ahí): esto
  conecta el flujo real de extremo a extremo con el motor placeholder, no
  simula un motor que no existe. Android nunca tuvo ningún archivo
  Avatar/Onboarding/Selfie — cerrarlo ahí sería construir la feature entera
  desde cero, no "conectarla", así que queda documentado como trabajo real
  pendiente, no fingido aquí. Sin verificación de compilador real (límite
  de plataforma iOS).
- **Hallazgo original (ya resuelto en iOS arriba)**: `SelfieConsentView.swift` y
  `AvatarProvider.generateAvatar()` están completamente construidos (con
  aviso de honestidad ejemplar sobre no conocer el SDK real de Avaturn/
  MetaPerson) pero **nunca se llaman desde ningún sitio** — `grep` de
  `SelfieConsentView(`/`generateAvatar` en todo el código: cero llamadas
  fuera de su propia definición. No existe ningún flujo de onboarding en
  absoluto en ninguna plataforma (tampoco hay ningún archivo Avatar/
  Onboarding/Selfie en Android). Diferencia importante con lo que dice el
  propio `README.md`: no es solo que `PlaceholderAvatarProvider` muestre "un
  círculo de color en vez de un avatar 3D real" — es que ningún usuario
  llega nunca a ese punto, porque no hay ninguna pantalla que dispare la
  captura de selfie ni el consentimiento. Construir un onboarding real
  (captura de cámara + consentimiento + llamada a generateAvatar + guardar
  `avatar_config`, en ambas plataformas) es un hueco de tamaño comparable a
  Stories/comentarios/chat multimedia — documentado aquí, no improvisado.
  **Confirmación adicional del lado de base de datos**: tampoco existe
  ningún trigger de Postgres tipo `on_auth_user_created`/`handle_new_user`
  que cree automáticamente una fila en `profiles` al registrarse un usuario
  en Supabase Auth, ni ningún `insert` a `profiles` en el código cliente de
  ninguna plataforma (`grep` de `from("profiles")...insert` en todo el
  repo: cero resultados). Es el mismo hueco raíz que "no existe flujo de
  registro/verificación de edad" (ya señalado en `privacy_policy_es.md`),
  confirmado ahora también desde el lado del esquema: aunque alguien se
  registrara en Supabase Auth directamente, no tendría fila en `profiles`
  y cualquier feature con foreign key a esa tabla fallaría.
- **RESUELTO en una pasada posterior** — comentarios reales construidos
  de punta a punta (tabla + RLS + trigger de contador + trigger de
  notificación + UI en ambas plataformas), ver `0008_comments.sql` en
  "Añadido esta sesión" arriba. Ya no es un hueco pendiente.
- **Hueco nuevo, encontrado por auditoría de honestidad de comentarios de
  código**: el docstring de `HomeScreen.kt`/`HomeView.swift` afirmaba
  "Historias, feed de publicaciones (like, comentar, enviar, guardar)" —
  falso en 4 de 5 puntos. No hay tabla `stories` consultada en ningún sitio
  del cliente (la tabla existe en 0001_schema.sql con RLS ya lista, pero
  cero código cliente en ninguna plataforma); los iconos de comentar/
  compartir/guardar en `PostCard` son `Image`/`Text` decorativos sin
  `onClick`/`Button` — solo el de like es real desde esta sesión. Corregido
  el comentario para que diga la verdad (ambas plataformas); NO se ha
  implementado Stories/comentarios/compartir/guardar — son funcionalidades
  completas por construir, no bugs de un botón. COMPILADO OK en Android.
- **`event_density()` — la métrica que `growth_strategy.md` llama "la que de
  verdad importa" — está efectivamente rota**: la función cuenta
  `analytics_events` con `event_id = p_event_id` en los últimos N minutos
  como señal de "sigue activo", pero `tab_view`/`app_open` (los únicos
  eventos que se disparan repetidamente mientras alguien usa la app) NUNCA
  llevan `event_id` — ni en `RootTabView.kt` ni en `RootTabView.swift`. El
  único evento que sí lleva `event_id` es `event_joined`, que se dispara UNA
  vez al unirse. Resultado: `event_density()` en la práctica mide algo
  parecido a "tasa de gente que se unió en los últimos N minutos", no "% de
  asistentes con actividad reciente" como dice su propio comentario. Arreglo
  real requiere compartir el estado de "evento activo actualmente unido"
  entre `EventModeViewModel` (con estado hoy encapsulado dentro de
  `SocialCameraScreen.kt`, donde vive Modo Evento) y el punto donde se
  registran `tab_view`/`app_open` en `RootTabView.kt` — un cambio de estado
  compartido entre composables, no una función aislada; se documenta en vez
  de improvisar un singleton/CompositionLocal a medias en una pasada de 60s.
  **RESUELTO en una pasada posterior**: en vez de compartir estado de
  Compose/SwiftUI entre `EventModeViewModel` y `RootTabView`, se añadió un
  holder en memoria (`AnalyticsManager.currentEventId`/`currentEventID`,
  mismo patrón singleton que `SupabaseManager`) que `joinEvent()` fija tras
  un `event_joined` real (no solo por detectar el evento cerca — `hasJoined`
  es la señal correcta) y que `track()` usa automáticamente como `event_id`
  para cualquier llamada sin uno explícito. Se limpia cuando
  `checkForNearbyEvent` ya no encuentra ningún evento activo cerca y el
  usuario había estado unido. COMPILADO OK en Android; en iOS aplicado el
  mismo cambio (sin verificación de compilador, límite de plataforma).

- **Hallazgo de integridad en `duel-ai` (Edge Function), no un bug de
  cliente**: `score_duel` confía en `questionCount`/`correctCount` que
  manda el cliente, sin ningún registro server-side de qué preguntas se
  generaron realmente en `generate_questions` ni de qué respondió el
  usuario. Un cliente modificado podría llamar directamente a la acción
  `score_duel` con valores inventados (p. ej. `correctCount = questionCount`
  siempre) para inflar artificialmente el `compatibility_delta` — que
  además afecta a `chats.compatibility_score`, visible y compartido con la
  otra persona del chat. El rate-limit (20/hora, `ai_usage`) sí está bien
  implementado y falla cerrado; este es un problema de integridad del
  resultado, no de gasto de API. Arreglarlo bien requiere que la Edge
  Function guarde una sesión de duelo server-side (preguntas + índices
  correctos, con un id de sesión) en `generate_questions` y valide las
  respuestas contra esa sesión en `score_duel` — cambio de diseño de la
  función, no verificable en este entorno (sin Deno/Postgres reales para
  probarlo). Documentado en vez de tocar la Edge Function a medias.
  **RESUELTO DE FONDO en una pasada posterior** (la mitigación de rango
  quedó obsoleta y fue reemplazada, no acumulada): al revisar el problema
  de nuevo se encontró que era MÁS grave de lo documentado —
  `generate_questions` mandaba `correctIndex` en claro al cliente (es
  parte del propio `DuelQuestion` usado para pintar las opciones), así que
  cualquiera podía ver la respuesta correcta antes de elegir, no solo
  falsificar el conteo final. Arreglado con `0010_duel_sessions.sql`
  (tabla solo legible por `service_role`, sin políticas RLS para
  `authenticated`/`anon` — mismo patrón que `ai_usage`) + reescritura de
  `duel-ai/index.ts`: `generate_questions` guarda las preguntas completas
  server-side y devuelve `{sessionId, questions}` sin `correctIndex`;
  `score_duel` recibe `{sessionId, answers}` (no un conteo que se pueda
  inventar) y calcula el acierto real contra la sesión guardada, marcando
  `used=true` para que no se pueda reutilizar la misma sesión dos veces ni
  puntuar una sesión ajena. Cliente actualizado en ambas plataformas:
  `DuelQuestion` ya no lleva `correctIndex`, `AnthropicDuelService`/
  `DuelViewModel` usan sessionId. **COMPILADO OK en Android** (confirma que
  ningún otro archivo dependía de la firma antigua), instalado y verificado
  sin crash en el emulador. Ya no es un hueco pendiente.

## Última pasada
- Ronda impar (siguiendo el mismo patrón de bug, verificación): comprobado si `EventLocationProvider` (otro `@StateObject` similar a `HeadingProvider`) tiene el mismo problema de "instanciado pero nunca consumido" — no lo tiene: `eventLocation.$location` se lee de verdad vía `.onReceive` y alimenta `eventMode.checkForNearbyEvent(location:)`. Bien cableado, sin hallazgos.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código en Android (el fix de HeadingProvider fue solo-Swift). Rebuild limpio, relanzado en el emulador real (PID 30328). Primera captura en negro por el mismo timing conocido de la cámara del emulador; segunda captura confirmó render correcto, sin FATAL en logcat.

- Ronda impar (hallazgo real, no toca render): revisando `HeadingProvider.swift` (correcto y bien escrito, no revisado hasta ahora) se comprobó dónde se usaba de verdad — `SocialCameraView.swift` lo instancia y lo arranca/para, pero **nunca lee `heading` ni `needsCalibration`**. El propio marcador y la guía "gira a la izquierda/derecha" (`aimingGuideText`) ya funcionan solo con el ángulo UWB relativo al dispositivo (`horizontalAngle`), igual que Android — el compás no aportaba nada, solo consumía batería y justificaba parte del permiso de ubicación sin necesidad real. Eliminada la instanciación inútil en `SocialCameraView.swift` (la clase se deja intacta, reservada para cuando exista de verdad el mapa "Find", que sí necesitaría rumbo real). Corregido también el texto de `NSLocationWhenInUseUsageDescription` en `Info.plist` y `app_store_permission_texts.md`, que afirmaba (incorrectamente) que la brújula estabilizaba el apuntado — ahora describe el uso real: detección de Modo Evento y, opcionalmente, el mapa Find. Build Android recompilado para confirmar que no se vio afectado (cambios aislados a Swift/plist/Markdown).

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 30181). Primera captura en negro por el mismo timing conocido de la cámara del emulador; segunda captura confirmó render correcto, sin FATAL en logcat.

- Ronda impar (verificación del protocolo de intercambio de profileId, no toca render): revisado que `SocialProximity.kt` (protocolo con tag "A|"/"C|" pipe-delimited) y `PeerToken.swift` (`DiscoveryTokenMessage`, `Codable`/JSON) siguen llevando `profileId`/`profileID` de forma consistente cada uno dentro de su propia plataforma — son formatos de wire distintos a propósito, no un bug: NearbyInteraction (iOS) y androidx.core.uwb (Android) no interoperan entre sí, cada plataforma solo hace ranging con peers de la misma plataforma, así que no hace falta un formato compartido, solo que cada uno sea internamente consistente (lo son). Sin hallazgos.

- Ciclo render+optimizar (pauta cada-dos-loops): verificación visual real navegando Social → Perfil → Ajustes → "Usuarios bloqueados" (feature nueva de la pasada anterior) — capturas reales confirman título, mensaje de error de red esperado (credenciales placeholder) y estado vacío correctos, sin FATAL en logcat. Confirma que la nueva pantalla funciona de extremo a extremo en el emulador, no solo que compila.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 30056), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Mantenimiento del propio documento (no toca render ni código): `LOOP_STATE.md` había crecido a 596 líneas, con la sección "Última pasada" acumulando decenas de entradas de pasadas ya resumidas en las secciones permanentes de arriba. Comprimidas las entradas más antiguas (todo lo anterior a las últimas ~10 pasadas) en un resumen de un párrafo, sin perder ningún hallazgo real — todos siguen en la lista numerada de bugs y en "Pendiente real". El archivo bajó de 596 a ~311 líneas. Verificado que `assembleDebug --offline` sigue limpio (cambio puramente documental).

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 29878). Primera captura en negro por el mismo timing conocido de la cámara del emulador; segunda captura confirmó render correcto, sin FATAL en logcat.

- Ronda impar (misma familia, confirmación sin duplicar hallazgo): comprobado que "Seguir de vuelta" en `AvisosScreen.kt` tiene exactamente el mismo patrón ya documentado para `sendSocial` — la hoja se cierra tras el primer toque, pero reabrir la misma notificación más tarde permitiría reintentar `follow()` sobre una fila ya existente, con el mismo tipo de mensaje de error genérico en vez de uno específico. Mismo caso, mismo veredicto (cosmético menor, protegido correctamente a nivel de base de datos) — no se duplicó como hallazgo nuevo en la lista, solo se confirmó que el patrón es consistente en todos los managers de esta familia.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 29746), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (mismo tipo de auditoría, continuación): a diferencia de `compat_requests` (bloqueado por estado de UI, caso límite sin impacto real), `sendSocial` sí es realmente reenviable — `SendSocialSheet` no lleva ningún estado "ya enviado" y se puede volver a detectar y tocar al mismo peer más tarde. Si ya existe la fila (`unique(requester_id, addressee_id)`), el catch genérico muestra "No se pudo enviar el social" sin aclarar que ya se había enviado antes — la constraint de la base de datos sí protege correctamente contra duplicados, es solo un mensaje de error poco claro, no un bug funcional ni de seguridad. No se tocó código: distinguir el tipo de error de forma fiable requeriría inspeccionar el tipo/código de la excepción real de supabase-kt, que no está verificado en este entorno — mejor documentarlo como cosmético menor que adivinar una comprobación de tipo no confirmada.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 29615), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (auditoría de manejo de errores, no toca render): revisado si `MatchViewModel.requestCompatibility` maneja bien una violación de la unique constraint `(requester_id, target_id)` de `compat_requests` (mismo tipo de caso que el 409 ya manejado explícitamente en `likes`) — trazado el flujo completo: `requestSent` se pone a `true` de forma optimista antes del insert, y `MatchScreen.kt` oculta el botón en cuanto eso pasa, así que un doble-envío solo sería alcanzable entre sesiones distintas (tras recargar y perder el estado local `requestSent`), y en ese caso la UI igual termina en el estado correcto ("Solicitado"), solo con un mensaje de error de más que no cambia nada visible. Caso límite real pero de impacto nulo — no se tocó código.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 29467), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (confirmación de hallazgo previo, no toca render): siguiendo el hilo de "no existe flujo de registro" (ya documentado desde la auditoría de `privacy_policy_es.md`), se comprobó el lado de la base de datos — tampoco hay ningún trigger `on_auth_user_created` que cree una fila en `profiles` al registrarse en Supabase Auth, ni ningún insert a `profiles` en el cliente. Confirma y precisa el mismo hueco raíz desde otro ángulo, añadido como nota conectada al hallazgo existente en vez de una entrada duplicada.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 29319), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (hallazgo grande, no toca render): continuando la auditoría de `Avatar/` de la pasada anterior, se comprobó si `SelfieConsentView`/`generateAvatar()` se llaman desde algún sitio — no se llaman desde ninguno, en ninguna plataforma. No hay onboarding en absoluto. Documentado en "Pendiente real" como un hueco de tamaño comparable a Stories/comentarios/chat multimedia, no una corrección rápida.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 29132), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (auditoría de la carpeta Avatar, no revisada hasta ahora): `ClothingStore.swift` (StoreKit 2 estándar, bien estructurado) y `AvatarProvider.swift` (ya ejemplarmente honesto sobre no conocer la firma real de Avaturn/MetaPerson) revisados sin hallazgos. Área ya cubierta correctamente desde antes de esta sesión.

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 28930), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (cierre de la búsqueda de propiedades muertas): revisados el resto de `@Published` de `MatchViewModel.swift` (`isLoading` correctamente activado/desactivado con `defer`) y `AvisosViewModel.swift` (`selected` correctamente asignado desde `AvisosView.swift` y ligado al `.sheet(item:)`) — ambos limpios. Con esto se da por cerrada la búsqueda de este patrón específico de bug (propiedad declarada pero nunca asignada) tras encontrar 2 casos reales (contadores de Perfil, `stories` muerta en Home) en las últimas rondas.

- Ciclo render+optimizar (pauta cada-dos-loops): rebuild limpio tras eliminar la propiedad muerta `stories` y corregir los comentarios. Reinstalado y relanzado en el emulador real (PID 28389), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (misma familia de bug que los contadores de Perfil): siguiendo el mismo patrón de búsqueda ("propiedad declarada, nunca asignada"), se encontró `HomeViewModel.swift.stories: [Post] = []` — código muerto real, nunca asignado en ningún sitio del archivo y nunca leído en `HomeView.swift`. Eliminada la propiedad. De paso, el propio header de `HomeViewModel.swift` (y el de `HomeViewModel.kt`) seguían diciendo "historias, feed..." — la misma afirmación falsa ya corregida en `HomeView.swift`/`HomeScreen.kt` unas pasadas atrás, pero que se me había pasado en estos dos archivos concretos. Corregidos ambos. COMPILADO OK en Android.

- Ciclo render+optimizar (pauta cada-dos-loops): el fix de contadores de la pasada anterior es solo-iOS (Swift), sin impacto en Android. Rebuild limpio, relanzado en el emulador real (PID 28229), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (auditoría de paridad, hallazgo real solo-iOS): comparando `PerfilViewModel.swift` con `PerfilViewModel.kt` (secciones idénticas, 15/15 claves en el mismo orden — sin bug ahí), se notó que iOS declara `postCount`/`followingCount`/`followerCount`/`socialCount` y `PerfilView.swift` los muestra en una fila de contadores bajo la cabecera ("Pubs"/"Siguiendo"/"Seguidores"/"Socials") — pero `load()` nunca los calculaba, se quedaban en 0 para siempre sin importar los datos reales. Corregido con `loadCounters(userID:)`: cuenta `posts` (author_id), `follows` (follower_id/followee_id) y `socials` aceptados (requester_id OR addressee_id) usando `select(head:count:)`, con el aviso de honestidad habitual sobre no poder verificar esa firma exacta con compilador aquí. Android no tiene esta fila de contadores en absoluto (su Perfil se rediseñó como lista de 15 secciones sin cabecera de contadores, decisión ya documentada) — este es un fix solo-iOS, no un hallazgo de paridad entre plataformas. Build Android recompilado para confirmar que no se vio afectado (cambio aislado a un archivo Swift).

- Ciclo render+optimizar (pauta cada-dos-loops): sin cambios de código. Rebuild limpio, relanzado en el emulador real (PID 28105), render confirmado correcto, sin FATAL ni MISSING_PERMISSION en logcat.

- Ronda impar (paridad de código, continuación): comparado `DuelScreen.kt` con `DuelView.swift` — mismo manejo de las 4 fases (loading/answering/scoring/finished), mismo flujo de preguntas y renderizado del resultado. Sin discrepancias reales. Sin hallazgos nuevos.

- Ronda impar (cierre de paridad, validación de longitud de perfil): completado en Android la pasada anterior (`PerfilViewModel.kt.updateBasicInfo`, límites 50/300 caracteres con guarda explícita, coherente con `0023_text_length_limits.sql`), ahora aplicado el mismo fix en iOS — `PerfilViewModel.swift.updateBasicInfo` no tenía ninguna validación de longitud (dependía por completo de que el `UPDATE` fallara en el servidor con un mensaje Postgres genérico) ni mensaje para nombre vacío (el `guard` original simplemente hacía `return` sin avisar). Añadidas las mismas guardas: nombre vacío → mensaje explícito; nombre >50 o bio >300 → mensaje explícito con el mismo texto que Android. Build Android recompilado (BUILD SUCCESSFUL, cambio aislado a archivo Swift, como se esperaba). Con esto se cierra la paridad de validación de perfil entre las dos plataformas.

- Ronda de auditoría de "Pendiente real" (esta pasada): releídas y
  re-verificadas contra el código actual 4 entradas que llevaban pasadas
  sin actualizarse tras resolverse — borrado de cuenta, chat multimedia
  (voz+reacciones), avatar onboarding Android — todas confirmadas ya
  construidas y funcionando, corregidas para dejar de aparecer como
  pendientes. Ningún cambio de código necesario; build Android
  recompilado para confirmar que el documento seguía coherente con el
  estado real (BUILD SUCCESSFUL).

- Ronda impar (hallazgo real solo-iOS, mismo bug en ambas plataformas al principio): auditando el sheet de edición de perfil se encontró que `EditProfileSheet.kt`/`EditProfileView.swift` cierran el sheet inmediatamente al pulsar "Guardar" (`onSave(...); dismiss()`), sin esperar el resultado de `updateBasicInfo`. En Android esto es inofensivo porque la validación (nombre vacío/>50, bio >300) es síncrona y `PerfilScreen.kt` ya muestra `viewModel.errorMessage` en la pantalla de fondo tras cerrarse el sheet. En iOS, en cambio, **`PerfilView.swift` nunca mostraba `viewModel.errorMessage` en ningún sitio** — el usuario podía escribir un nombre de 80 caracteres, pulsar Guardar, ver el sheet cerrarse, y no tener ninguna pista de por qué el cambio no se guardó. Corregido añadiendo el mismo `Text(error)` condicional que ya existe en Android, justo encima del botón "Editar perfil". Build Android recompilado para confirmar que el cambio (solo Swift) no lo afectó (BUILD SUCCESSFUL).

- Ronda impar (hallazgo real de privacidad, mismo bug en ambas plataformas): comparando `SearchViewModel.kt`/`SearchViewModel.swift` con `HomeViewModel`/`MatchViewModel`, se notó que Home y Match sí aplican `eq("is_invisible", false)` (excluir a quien activó "modo invisible" desde `SocialCameraScreen.kt`/`SocialCameraView.swift`) pero el buscador por nombre no filtraba por esa columna en ninguna plataforma — alguien en modo invisible seguía siendo perfectamente localizable por nombre exacto, dejando la promesa de privacidad del toggle a medias (solo ocultaba de la cámara de proximidad, no de la búsqueda global). Corregido en ambas plataformas añadiendo el mismo filtro ya probado en Home/Match. **Android: COMPILADO OK** (`assembleDebug` limpio, cambio aislado al bloque `filter {}` del mismo patrón ya usado en `HomeViewModel.kt`/`MatchViewModel.kt`; reinstalado y relanzado en el emulador real esta pasada tras localizar `adb` en `C:\Users\assce\AndroidSdk\platform-tools` — ruta distinta a la usada en pasadas anteriores, ahora anotada por si vuelve a hacer falta —, PID 5866, sin FATAL en logcat). iOS con el mismo cambio, sin verificación de compilador real (límite de plataforma).

- Ronda impar (auditoría de paridad, sin hallazgos nuevos): comprobados `location_public`/`compat_public` (gatean campos individuales, no la visibilidad completa del perfil — uso correcto en ambas plataformas, distinto de `is_invisible`), pull-to-refresh (ya presente en las 4 pantallas relevantes en ambas plataformas, un grep case-sensitive anterior lo había pasado por alto) y `is_verified` en Match (solo aparece en un comentario, no hay uso real ahí en ninguna plataforma). Sin hallazgos, sin cambios de código.

- Ronda grande de funcionalidad nueva (no bug): comparando con Instagram/TikTok/Snapchat, las tres muestran una notificación real del sistema cuando llega un aviso nuevo (like, seguidor, mensaje...) aunque el usuario esté en otra pantalla — SOCIAL solo actualizaba números en la app (badge de la pestaña Avisos), invisible fuera de ella. Construidas notificaciones locales reales en ambas plataformas, con el aviso de honestidad correspondiente: **no es push real** (FCM/APNs), solo funciona mientras el proceso sigue vivo (misma limitación que cualquier suscripción Realtime por WebSocket sin un backend de push de verdad detrás) — documentado así en vez de fingir push verdadero, push real queda como el hueco grande ya conocido en "Pendiente real".
  - **Android (COMPILADO Y VERIFICADO EN EJECUCIÓN, PID 6004, sin FATAL)**: `LocalNotifier.kt` (nuevo) crea el canal de notificación y publica usando `NotificationEntry.title()`/`icon()` ya existentes; `NotificationsBadgeViewModel.kt` decodifica el `insert.record` completo (antes solo traía `id,read_at`) y llama a `LocalNotifier.notify()` en cada inserción real-time, con `appContext` pasado explícitamente desde `RootTabView.kt` (`LocalContext.current.applicationContext`, no una Activity — sin riesgo de fuga de memoria). Añadido permiso `POST_NOTIFICATIONS` al manifest y solicitud en tiempo de ejecución (API 33+) con el mismo patrón `rememberLauncherForActivityResult` ya usado para el micrófono en `ChatScreen.kt`. Sin icono monocromo propio en `res/` — se usa el icono de sistema `android.R.drawable.ic_dialog_info` en vez de inventar un asset nuevo.
  - **iOS (sin verificación de compilador real, límite de plataforma)**: `AvisosViewModel.swift.start()` pide autorización de `UNUserNotificationCenter` y `postLocalNotification(for:)` publica un aviso local en cada inserción real-time. **Diferencia real de alcance frente a Android, documentada explícitamente**: en iOS esto solo suena mientras `AvisosView` ha llegado a montarse al menos una vez (su propio `@StateObject`), no desde el arranque de toda la app como en Android (`RootTabView.kt`) — elevarlo al mismo nivel (un ViewModel de raíz) queda anotado como trabajo real pendiente, no fingido aquí.

- Ronda impar (cierre del matiz de alcance iOS documentado en la pasada anterior): `NotificationsBadgeViewModel.swift` SÍ arranca desde `RootTabView.swift` al abrir la app (cualquier pestaña), a diferencia de `AvisosViewModel.swift` que solo vive mientras `AvisosView` se ha montado — era el sitio correcto para publicar la notificación local a nivel de toda la app, igual que Android. Movida la lógica: `NotificationsBadgeViewModel.swift` ahora pide autorización de `UNUserNotificationCenter` en `start()` y publica el aviso decodificando `AvisosViewModel.NotificationEntry` (reutilizado, no duplicado) en cada inserción real-time; quitada la publicación duplicada de `AvisosViewModel.postLocalNotification` (habría sonado dos veces con la pestaña Avisos abierta) junto con su import ya sin uso. Con esto, iOS queda en paridad real de alcance con Android — ambos suenan desde el arranque de la app, no solo dentro de una pestaña. Build Android recompilado para confirmar que no se vio afectado (cambio aislado a archivos Swift).

- Ronda grande de funcionalidad nueva (no bug): comparando con el Explorar de Instagram y la búsqueda de TikTok, ambas dejan buscar contenido por etiqueta además de personas — el buscador de SOCIAL (construido unas pasadas atrás) solo buscaba perfiles por nombre. Añadida búsqueda por hashtag en ambas plataformas: un texto que empieza por "#" busca en `posts.caption` (ILIKE, sin columna ni RPC nuevos — `posts_select` de 0002_rls.sql ya permite leer cualquier post público) en vez de en `profiles`, mostrando la lista de publicaciones que la contienen (caption + contador de likes/comentarios) en vez de la lista de personas; tocar un resultado abre el perfil del autor (reutilizando `onOpenProfile`/`ProfileViewerView`, sin construir una pantalla de detalle de post nueva — alcance deliberadamente acotado). **Android: COMPILADO Y VERIFICADO EN EJECUCIÓN** (`assembleDebug` limpio, reinstalado y relanzado en el emulador real, PID 6845, sin FATAL en logcat). iOS con el mismo cambio en `SearchViewModel.swift`/`SearchView.swift`, sin verificación de compilador real (límite de plataforma); build Android recompilado tras el cambio iOS para confirmar que no lo afectó (BUILD SUCCESSFUL).

- Ronda de funcionalidad nueva (cierre del hueco dejado por la búsqueda por hashtag de la pasada anterior): la búsqueda por "#etiqueta" ya funcionaba, pero no había ninguna forma de llegar ahí desde una publicación real del feed — había que teclear la etiqueta de memoria, algo que ninguna app grande exige (Instagram/TikTok: tocar la etiqueta en el caption abre su búsqueda). Construidas etiquetas tocables en el caption de cada post, en ambas plataformas.
  - **Android (COMPILADO Y VERIFICADO EN EJECUCIÓN, PID 7174, sin FATAL)**: `CaptionText`/`buildAnnotatedStringWithHashtags` (nuevo, en `HomeScreen.kt`) usa `ClickableText`+`AnnotatedString` con `pushStringAnnotation`/`getStringAnnotations` para detectar el toque exacto sobre una etiqueta; nueva ruta `search_hashtag/{tag}` en `RootTabView.kt` (codificada con `URLEncoder`/`URLDecoder` — las etiquetas pueden llevar cualquier carácter Unicode) que abre `SearchScreen` con `initialHashtag`, nuevo parámetro que precarga la búsqueda vía `LaunchedEffect`. Un primer intento falló en compilación (`withStyle` sin resolver dentro de `buildAnnotatedString` — hacía falta el import explícito `androidx.compose.ui.text.withStyle`, no solo el receiver implícito), corregido y reverificado.
  - **iOS (sin verificación de compilador real, límite de plataforma)**: mismo resultado con herramientas propias de SwiftUI — `AttributedString.link` con un esquema propio no-real (`socialhashtag://tag`, solo como transporte) interceptado vía `.environment(\.openURL)` en `PostCard` (`HomeView.swift`), y `.navigationDestination(item: $hashtagToOpen)` empuja `SearchView(initialHashtag:)` (nuevo parámetro, precarga `viewModel.query` en `.task`). Build Android recompilado tras el cambio iOS para confirmar que no lo afectó (BUILD SUCCESSFUL).

- Ronda grande de funcionalidad nueva (no bug): comparando con WhatsApp/Instagram DM, ninguna de las dos suelta a la otra persona sin señal de "Escribiendo…" — el chat de SOCIAL no tenía ninguna. Construido con Realtime Broadcast (efímero, sin tabla ni columna nueva) sobre el mismo canal `chat-{chatId}` ya abierto para mensajes/reacciones/lectura, con debounce de 300ms al teclear y auto-apagado a los 3s sin nuevo evento (mismo criterio que WhatsApp, que tampoco manda un "dejé de escribir" explícito).
  - **Android (COMPILADO Y VERIFICADO EN EJECUCIÓN, PID 7319, sin FATAL)**: API real `broadcast`/`broadcastFlow` de `realtime-kt` confirmada existente decompilando el AAR en caché de Gradle (`io.github.jan.supabase.realtime.RealtimeChannelKt.broadcastFlow`/`.broadcast`, no adivinada) antes de escribir el código — compiló a la primera. `ChatViewModel.kt.notifyTyping()`/`isOpponentTyping`, wireado en `ChatScreen.kt` (`onValueChange` del campo de texto + texto "Escribiendo…" sobre el compositor).
  - **iOS (sin verificación de compilador real, límite de plataforma)**: mismo patrón con `channel.broadcastStream(event:)`/`channel.broadcast(event:message:)` de supabase-swift 2.x y el tipo `AnyJSON`/`.stringValue` ya usado en `reactionDeletes` de este mismo archivo — API razonada por analogía con el resto de la sesión, no verificada con compilador real, con el aviso de honestidad correspondiente en el código. `ChatViewModel.swift.notifyTyping()`/`isOpponentTyping`, wireado en `ChatView.swift`. Build Android recompilado tras el cambio iOS para confirmar que no lo afectó (BUILD SUCCESSFUL).

- Ronda grande de funcionalidad nueva (no bug, continuación directa de la pasada anterior): junto con "Escribiendo…", WhatsApp/Instagram DM también muestran si la otra persona tiene la conversación abierta ahora mismo ("En línea"). Construido con Presence de Realtime (efímero, mismo canal `chat-{chatId}` ya abierto) — alcance deliberadamente acotado: "en línea" significa "tiene este chat abierto", no un sistema de presencia global de toda la app (esa sería una pieza de infraestructura mayor, no fingida aquí).
  - **Android (COMPILADO Y VERIFICADO EN EJECUCIÓN, PID 7992, sin FATAL)**: API real `track`/`untrack`/`presenceChangeFlow` de `realtime-kt` confirmada existente decompilando el mismo AAR en caché de Gradle que ya sirvió para verificar `broadcast` la pasada anterior — `channel.track(JsonObject)`, `PresenceAction.joins`/`.leaves: Map<String, Presence>`. `ChatViewModel.kt` recalcula `onlineUserIds` desde joins/leaves (nunca un contador a mano, para no desincronizarse si se pierde algún evento), wireado en `ChatScreen.kt` como "🟢 En línea" bajo la barra de compatibilidad.
  - **iOS (sin verificación de compilador real, límite de plataforma — aviso de honestidad más fuerte de lo habitual en el código)**: a diferencia de `broadcastStream` (visto por analogía directa con un método hermano ya usado en este mismo archivo), la superficie exacta de Presence en supabase-swift no se ha visto en ningún otro sitio de este proyecto — `channel.track(_:)`/`channel.presenceChange()` razonados por simetría con la API Kotlin del mismo SDK, marcado explícitamente como el punto de mayor riesgo de esta pasada si la firma real difiere. Build Android recompilado tras el cambio iOS para confirmar que no lo afectó (BUILD SUCCESSFUL).

- Ronda impar (limpieza de warnings reales del compilador, sin cambio de comportamiento): `./gradlew clean assembleDebug` de la pasada anterior sacó a la luz 4 variables/parámetros nunca usados, cada uno confirmado inofensivo antes de tocarlo (no un hueco a medio construir): `context`/import `LocalContext` en `AvatarOnboardingScreen.kt` (el "avatar" placeholder genera un color aleatorio, nunca toca la foto real — mismo criterio honesto documentado en el propio archivo), `myId`/import `SupabaseManager` en `StoriesBar.kt`, `scope`/import `rememberCoroutineScope` en `MyPostsScreen.kt`. Eliminados los 4 junto con sus imports. Build limpio recompilado: 0 warnings de variable no usada, solo quedan warnings preexistentes de `Divider` deprecado (fuera de alcance, cosmético, sin urgencia). Cerrado el daemon de Gradle al terminar (`./gradlew --stop`), siguiendo la nueva regla de rendimiento del ordenador del usuario anotada al principio de este documento.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 7 arreglos reales esta pasada.
  1-5. Los 5 usos restantes de `Divider` (deprecado, se renombra a `HorizontalDivider` en Material3) en `ChatListScreen.kt`, `BlockedUsersScreen.kt`, `CompatSharesScreen.kt`, `MyPostsScreen.kt`, `SocialsListScreen.kt` — cada import y cada llamada corregidos. Build limpio: 0 warnings de deprecación restantes en todo el proyecto.
  6. **Hallazgo real de privacidad (más grave que el del buscador, mismas dos pasadas atrás)**: `FindLocationsViewModel.kt` (el mapa de "Find") filtraba por `location_public = true` pero nunca por `is_invisible = false` — alguien en modo invisible con ubicación pública seguía apareciendo en el mapa con sus coordenadas exactas. Corregido añadiendo el mismo filtro ya aplicado en Home/Match/Search.
  7. Mismo hallazgo, mismo fix en `FindLocationsViewModel.swift` (iOS).
  Build Android recompilado tras los 7 cambios: BUILD SUCCESSFUL, 0 warnings. **Verificado en ejecución real**: emulador arrancado desde cero (cerrado la pasada anterior según la regla de rendimiento), reinstalado, relanzado, PID 2212, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 5 arreglos reales esta pasada, todos de la misma familia — bloqueo de usuario incompleto en distintos listados.
  1. El único warning restante del proyecto (`NotificationsBadgeViewModel.kt`, parámetro `userId` nunca usado) — no era solo cosmético: la consulta confiaba enteramente en RLS sin filtro explícito por `recipient_id`. Añadido como defensa en profundidad.
  2. **Hallazgo real**: la búsqueda por hashtag (construida dos pasadas atrás) no excluía publicaciones de gente bloqueada, a diferencia de la búsqueda de perfiles. Corregido en `SearchViewModel.kt`.
  3. Mismo fix en `SearchViewModel.swift` (iOS) — de paso, `BlockRow` estaba duplicado como struct local en dos funciones distintas del mismo archivo; movido a scope de fichero.
  4. **El más grave de esta pasada**: el feed principal de Home (`HomeViewModel.kt`) nunca filtraba publicaciones de gente bloqueada — a diferencia de Match/Find/Search (sí lo hacen), bloquear a alguien no ocultaba sus publicaciones del sitio que más se mira de toda la app. Un primer intento introdujo un error de compilación real (`blockedIds` declarado dos veces en el mismo `try`, la segunda vez para "Recomendados") — corregido reutilizando la primera declaración, recompilado limpio.
  5. Mismo hallazgo, mismo fix en `HomeViewModel.swift` (iOS) — el cálculo de `blockedIDs` (antes solo para "Recomendados") se movió arriba para aplicarse también al feed, sin duplicar el fetch.
  6. **La lista de chats (Android e iOS) seguía mostrando conversaciones con gente bloqueada** — el envío de mensajes ya estaba bloqueado en el servidor desde antes (`0013_block_enforcement_chat.sql`), pero el chat en sí seguía apareciendo en la lista, algo que ninguna app de mensajería grande hace. Corregido en `ChatListViewModel.kt`/`ChatListViewModel.swift`.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL, 0 warnings. **Verificado en ejecución real**: reinstalado, relanzado, PID 3520, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 arreglos reales esta pasada, todos de la misma familia — `0023_text_length_limits.sql` (límites reales de longitud en `posts.caption`/`messages.body`/`comments.body`) nunca se validó en el cliente para 3 de los 4 campos, a diferencia de nombre/bio de perfil (sí se cerró hace unas pasadas). Mismo patrón que la ronda de bloqueo de la pasada anterior: un hueco encontrado, auditado sistemáticamente en el resto de campos equivalentes.
  1. `posts.caption` (límite 2200) — `NewPostViewModel.kt.post()`.
  2. Mismo fix en `NewPostViewModel.swift` (iOS).
  3. `messages.body` (límite 2000) — `ChatViewModel.kt.sendMessage()`.
  4. Mismo fix en `ChatViewModel.swift` (iOS).
  5. `comments.body` (límite 500, el único de los cuatro que ya tenía constraint desde `0008_comments.sql`, antes de la migración 0023) — `CommentsViewModel.kt.addComment()`.
  6. Mismo fix en `CommentsViewModel.swift` (iOS).
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 3099, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 arreglos reales esta pasada, dos familias distintas seguidas hasta el final.
  1. **Migración `0024_more_text_length_limits.sql`**: auditados todos los campos de texto insertados desde el cliente en busca de los que `0023` no cubrió — encontrados 2: `profile_sections.content->>'texto'` (las 15 secciones editables del perfil completo) y `reports.reason`/`reports.details` (denuncias), ninguno con límite real hasta ahora.
  2. `PerfilViewModel.kt.saveSection()` — validación de 2000 caracteres.
  3. Mismo fix en `PerfilViewModel.swift.saveSection()` (iOS).
  4. `SafetyManager.kt.report()` — validación de 1000 caracteres en "details" (único campo libre del formulario; "reason" es una de las opciones fijas de `ReportSheet.kt`, no texto libre).
  5. Mismo fix en `SafetyManager.swift.report()` (iOS).
  6. **Migración `0025_block_enforcement_reactions.sql`**: siguiendo el mismo hilo de bloqueo de las últimas pasadas, se encontró que `message_reactions_insert` (0018) nunca comprobaba `blocks` — a diferencia de mensajes (0013) y likes/comments (0012), reaccionar con un emoji a un mensaje antiguo de alguien bloqueado seguía siendo posible (la fila `chats` no se borra al bloquear). Corregido con el mismo patrón exacto de `messages_insert`.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 3458, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 migraciones nuevas esta pasada, la más densa en hallazgos de seguridad real de toda la sesión. **Aviso de honestidad general para las 6**: son cambios de esquema/RLS puros — este entorno sigue sin Postgres local instalable (límite ya documentado), así que la sintaxis está razonada y revisada con cuidado (mismo patrón exacto que migraciones ya aplicadas con éxito, como 0013), pero no ejecutada contra una base de datos real. Build Android recompilado igualmente para confirmar que ningún cambio de cliente se vio afectado (BUILD SUCCESSFUL, ninguno esperado — son solo SQL).
  1. **`0026_follows_delete.sql`**: `follows` nunca tuvo política de borrado — `FollowManager.kt/.swift.unfollow()` llevaba desde su construcción llamando a un `.delete()` que Postgres denegaba en silencio (RLS cerrado por defecto no lanza excepción, solo borra cero filas). Dejar de seguir a alguien no funcionaba de verdad en ninguna plataforma, sin que ningún error lo delatara.
  2. **`0027_block_enforcement_votes.sql`**: mismo hallazgo que reacciones (pasada anterior) aplicado a `compatibility_votes` — votar la compatibilidad de un chat con alguien bloqueado seguía siendo posible.
  3. **`0028_block_enforcement_duels.sql`**: mismo hallazgo aplicado a `duels` — retar a duelo a alguien bloqueado seguía siendo posible (y `duels_insert` ni siquiera comprobaba que `opponent_id` fuera un socio real de chat).
  4. **`0029_protect_is_verified.sql` — el hallazgo de seguridad más grave de toda la sesión**: `profiles_update_own` solo comprobaba que la fila fuera propia (RLS es por FILA, no por COLUMNA) — un cliente modificado podía mandar `UPDATE profiles SET is_verified = true` directamente por la API REST, autoconcediéndose la insignia de verificado sin pasar por ningún proceso real. Cerrado con un trigger que revierte `is_verified` a su valor anterior salvo que la operación venga de `service_role`.
  5. **`0030_event_attendees_social_count.sql`**: mismo tipo de hueco de columna que `is_verified` — `event_attendees_insert_own` no restringía `social_count` (la columna que ordena el ranking de Modo Evento), así que un cliente modificado podía unirse a un evento con `social_count = 999999` y falsear el ranking. Cerrado exigiendo `social_count = 0` al insertar.
  6. **`0031_event_social_count_trigger.sql` — hallazgo funcional, no de seguridad**: auditando el hueco anterior se descubrió que `social_count` nunca se incrementaba en ningún sitio, ni trigger ni cliente — el ranking de Modo Evento mostraba siempre 0 para todo el mundo, la función central de esa pantalla nunca funcionó. Construido un trigger real: cuando un `social` pasa a `accepted`, si ambas partes son asistentes del mismo evento activo (`now() between starts_at and ends_at`), incrementa `social_count` para las dos.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 arreglos más, continuación directa de la auditoría "columna de confianza escribible por el cliente" (RLS es por fila, no por columna) que empezó con `is_verified`/`social_count` la pasada anterior. Mismo aviso de honestidad: son migraciones SQL puras, razonadas y revisadas con cuidado (siguiendo patrones ya aplicados con éxito en este proyecto) pero no ejecutadas contra Postgres real (límite de entorno ya documentado).
  1. **`0032_protect_compatibility_score.sql` — el hallazgo más interesante técnicamente**: `ChatViewModel.kt/.swift.vote()` calculaba el nuevo `compatibility_score` EN EL CLIENTE y lo escribía directamente — un cliente modificado podía saltarse el voto real. Solución de dos triggers: uno que aplica el delta desde `compatibility_votes` (la fuente de verdad), otro que revierte escrituras directas. Con un matiz importante detectado a tiempo: el trigger de protección no puede usar `auth.role() <> 'service_role'` (como sí vale para `is_verified`, protegido por una llamada API real) porque aquí el escritor de confianza es un trigger anidado en la misma sesión del cliente — `auth.role()` seguiría siendo 'authenticated' y revertiría también la escritura legítima. Corregido con `pg_trigger_depth() <= 1` en su lugar, que sí distingue la sentencia UPDATE directa del cliente (profundidad 1) de la disparada en cascada desde el INSERT del voto (profundidad >1).
  2. `ChatViewModel.kt.vote()` ya no escribe `chats` directamente — solo inserta el voto real, el número autoritativo llega por Realtime (suscripción que ya existía).
  3. Mismo fix en `ChatViewModel.swift.vote()` (iOS).
  4. **`0033_protect_post_counts.sql`**: mismo patrón `pg_trigger_depth()` aplicado a `posts.like_count`/`comment_count` — `posts_write_own` es `for all` (cubre UPDATE), así que el AUTOR de un post podía inflar sus propias métricas directamente, saltándose los triggers reales de `likes`/`comments` (0007/0008).
  5. **`0034_protect_duel_scoring.sql`**: mismo patrón `auth.role()` (como `is_verified`, no `pg_trigger_depth()` — aquí el escritor de confianza es la Edge Function `duel-ai` con clave `service_role`, una llamada API real, no un trigger anidado) aplicado a `duels.compatibility_delta`/`explanation`/`completed_at` — el cliente real nunca los escribe directamente (los calcula la IA), pero uno modificado podía falsear el resultado de un duelo sin pasar por ella.
  6. **Retoque de UX ligado al fix 1-3**: quitar la escritura directa de `compatibility_score` introduce un retraso perceptible (antes la barra se movía al instante, ahora espera la vuelta completa voto→trigger→Realtime). Restaurado el feedback optimista de forma segura: `_compatibility.value`/`compatibilityScore` se actualiza localmente al votar, PERO ya no se escribe nunca a la base de datos — el valor real de `chats` lo sobrescribe en cuanto llega por Realtime. Aplicado en ambas plataformas.
  Build Android recompilado tras los 6 cambios (incluidos los de cliente 2/3/6): BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 3241, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 arreglos esta pasada — vuelta a funcionalidad nueva tras varias rondas seguidas de solo SQL/seguridad, más el barrido de auditoría de bloqueo que sigue dando frutos.
  1-2. **"Guardados" — hallazgo real de funcionalidad, comparado con Instagram**: `HomeViewModel.toggleSave()`/`NewPostViewModel` llevan varias pasadas guardando de verdad en `saved_posts` (icono de marcador en cada post), pero no existía NINGUNA pantalla en ninguna plataforma para ver lo guardado — guardar un post no llevaba a ningún sitio. Construidas `SavedPostsScreen.kt`/`SavedPostsView.swift` (mismo patrón que `MyPostsScreen.kt`/`MyPostsView.swift`, con `unsave()`/`Quitar` para deshacer desde la propia lista), usando el embebido `saved_posts` → `posts(*)` de PostgREST (mismo criterio ya compiler-verificado en `EventModeViewModel.kt`), wireadas en `PerfilScreen.kt` (botón "🔖 Guardados") y `PerfilView.swift` (tile "Guardados" en la rejilla de subsecciones). **Android: COMPILADO Y VERIFICADO EN EJECUCIÓN** (PID 5545, sin FATAL — un ANR de `com.android.systemui` no relacionado con la app se descartó explícitamente comprobando que el PID de SOCIAL seguía vivo y sin su propio FATAL/ANR en logcat). iOS sin verificación de compilador real.
  3-4. Auditando la pantalla recién construida contra el mismo criterio ya aplicado en Home/Match/Find/Search/ChatList: "Guardados" tampoco filtraba publicaciones de gente bloqueada. Corregido en ambas plataformas en el mismo momento de construirlo, no como hallazgo posterior.
  5-6. **Mismo hallazgo aplicado a "Tus socials"**: bloquear a alguien no borra la fila de `socials` ya aceptada (son conceptos independientes) — sin filtro, alguien bloqueado seguía apareciendo en `SocialsListViewModel.kt`/`.swift`. Corregido en ambas plataformas.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 arreglos de consistencia UX esta pasada — auditando pull-to-refresh (ya presente en Home/Match/ChatList desde hace tiempo) contra el resto de pantallas de lista de Perfil, se encontró que `MyPostsScreen`/`SavedPostsScreen`/`SocialsListScreen` (esta última construida hace varias pasadas, las otras dos incluida la de esta sesión) no lo tenían, en ninguna plataforma — comparado con Instagram/Twitter/Facebook, es un gesto básico esperado en cualquier lista.
  1-3. Android: añadido `PullToRefreshContainer`/`rememberPullToRefreshState` (mismo patrón exacto ya usado en `HomeScreen.kt`) a `SavedPostsScreen.kt`, `MyPostsScreen.kt`, `SocialsListScreen.kt`. Compilado a la primera en los 3 casos.
  4-6. iOS: añadido `.refreshable { await viewModel.load() }` (una sola línea por pantalla, API nativa de SwiftUI) a `SavedPostsView.swift`, `MyPostsView.swift`, `SocialsListView.swift`.
  Quedan `BlockedUsersScreen`/`CompatSharesScreen` con el mismo hueco, no cerrado esta pasada por presupuesto de tiempo — anotado aquí para una ronda futura, no perdido. Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 2269, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande: cierre de pull-to-refresh en las 2 pantallas que quedaban (`BlockedUsersScreen.kt`/`.swift`, `CompatSharesScreen.kt`/`.swift`) — con esto queda cerrado por completo el barrido de esa familia de hallazgo en toda la app, ambas plataformas. Además, respondiendo a la petición explícita del usuario de "potenciar la IA", se auditó qué funciones de IA existen de verdad en el proyecto y se encontró una real y grave: **`activities.suggestion` (el campo "✨ Actividad sugerida" que aparece en el chat cuando la compatibilidad supera el 50%) llevaba TODA la sesión leyendo de una tabla en la que nada insertaba nunca** — ni trigger, ni cliente, ni ninguna Edge Function. `checkActivitySuggestion()` en ambas plataformas siempre fue código real (nunca fingido), pero conectado a un pozo permanentemente vacío.
  - Construida `supabase/functions/activity-ai/index.ts`, nueva Edge Function que sigue exactamente el mismo patrón ya probado en `duel-ai` (proxy hacia Anthropic, `ANTHROPIC_API_KEY` nunca sale del servidor, rate limit compartido vía `ai_usage`, verificación real de que el usuario es miembro del chat antes de generar nada). Genera una sugerencia real a partir de los intereses de ambos perfiles y el `compatibility_score`, la guarda en `activities` y la devuelve — solo se genera una vez por chat (si ya existe una fila, se devuelve esa en vez de gastar otra llamada a la IA).
  - `ChatViewModel.kt.checkActivitySuggestion()`: si no hay sugerencia guardada y la compatibilidad supera 50%, ahora llama a `activity-ai` de verdad en vez de quedarse en `null` para siempre. **COMPILADO Y VERIFICADO EN EJECUCIÓN** (`assembleDebug` limpio con `clean` de por medio para descartar caché, instalado y relanzado en el emulador real, PID 2226, sin FATAL en logcat) — incluyó un import real que faltaba (`io.github.jan.supabase.functions.functions`, `io.ktor.client.statement.bodyAsText`), detectado y corregido antes de dar el cambio por bueno.
  - Mismo fix en `ChatViewModel.swift.checkActivitySuggestion()` (iOS), llamando a `activity-ai` con el mismo patrón ya usado en `AnthropicDuelService.swift.invokeDuelAI`. Sin verificación de compilador real (límite de plataforma). Build Android recompilado tras el cambio iOS para confirmar que no lo afectó (BUILD SUCCESSFUL).
  - **Pendiente real para que esta función funcione contra un proyecto real**: desplegarla (`supabase functions deploy activity-ai`) — no distinto del resto de Edge Functions de este proyecto, que tampoco se han desplegado nunca contra un Supabase real (mismo bloqueo ya documentado: credenciales placeholder).

- Ronda grande, continuación directa de "potenciar la IA" (petición explícita del usuario): construida la segunda función de IA nueva de la sesión, comparando con Hinge ("Your Turn")/Bumble ("Opening Move") — ninguna app grande de citas/social deja un chat nuevo con el campo de texto vacío sin ayuda para arrancar la conversación, y SOCIAL no tenía nada parecido.
  1. `supabase/functions/icebreaker-ai/index.ts` (nueva): mismo patrón exacto que `duel-ai`/`activity-ai` (proxy hacia Anthropic, rate limit vía `ai_usage`, verificación real de membresía del chat), pero deliberadamente SIN persistencia — es una sugerencia efímera, no una fila más en una tabla.
  2. `ChatViewModel.kt.loadIcebreaker()`: se pide automáticamente cuando `loadHistory()` encuentra el chat vacío (chat nuevo). **COMPILADO Y VERIFICADO EN EJECUCIÓN** (PID 2691, sin FATAL).
  3. UI en `ChatScreen.kt`: chip "✨ sugerencia" tocable encima del compositor — tocarla rellena el borrador (nunca se envía sola), con botón "✕" para descartarla.
  4-5. Mismo fix completo (ViewModel + UI) en `ChatViewModel.swift`/`ChatView.swift` (iOS), sin verificación de compilador real.
  6. **Hallazgo real encontrado auditando el propio feature recién construido**: si el usuario ignoraba la sugerencia y escribía su propio mensaje (o mandaba foto/nota de voz), el chip se quedaba visible para siempre — nada lo limpiaba salvo tocarlo o su "✕". Corregido limpiando `icebreaker`/`_icebreaker.value` al principio de `sendMessage`/`sendPhoto`/`sendVoiceNote`, en ambas plataformas.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. Emulador y daemon de Gradle cerrados de nuevo al terminar. **Pendiente real para que funcione contra un proyecto real**: desplegar `icebreaker-ai` igual que el resto de Edge Functions (bloqueo ya documentado: credenciales placeholder).

- Ronda grande, hacia "listo para lanzar" (petición explícita del usuario): documentación real de despliegue + un hallazgo de integridad serio encontrado auditando el propio trabajo de una pasada anterior.
  1. **`supabase/DEPLOYMENT.md` (nuevo)**: no existía ninguna guía de cómo desplegar las 34 migraciones y 4 Edge Functions acumuladas contra un proyecto Supabase real — orden de migraciones, secretos (`ANTHROPIC_API_KEY`), despliegue de funciones, credenciales del cliente (`local.properties`/`Config.plist`), y honestidad explícita sobre qué sigue bloqueado sin un humano incluso después de conectar Supabase (Xcode, cuentas de tienda, KYC, UWB en dispositivo real).
  2-6. **Hallazgo de integridad real, más grave que el que se creía cerrado en `0034_protect_duel_scoring.sql`**: esa migración protegía `duels` contra UPDATE, pero el hueco real estaba en el INSERT — `DuelViewModel.kt/.swift` insertaban la fila completa en `duels` (incluido el `compatibility_delta`/`explanation` que la IA devolvía) directamente desde el cliente; un cliente modificado podía guardar cualquier resultado sin jugar un duelo real, sin que `0034` lo detectara (esa protección solo cubre UPDATE, nunca se disparó). Corregido de fondo, no con otro parche superficial: `duel-ai/index.ts` ahora INSERTA ella misma la fila en `duels` (con `service_role`, tras verificar sesión real) en vez de solo devolver el delta al cliente; `0035_duels_insert_service_role_only.sql` revoca el INSERT directo del cliente por completo (la única vía de creación pasa a ser esa función); `AnthropicDuelService.kt/.swift.scoreDuel()` manda ahora `chatId`/`opponentId` a la función; `DuelViewModel.kt/.swift` ya no escriben `duels` en absoluto (eliminada `save()`/imports ya sin uso). **Android: COMPILADO Y VERIFICADO EN EJECUCIÓN** (PID 2697, sin FATAL). iOS con el mismo fix, sin verificación de compilador real.

- Ronda de verificación real (no solo relectura): las 4 Edge Functions (`duel-ai`, `activity-ai`, `icebreaker-ai`, `delete-account`) nunca habían pasado por ninguna herramienta real — "razonadas y revisadas con cuidado" hasta ahora, honestamente, no verificadas. Este entorno sí tiene Node (`v24.15.0`, confirmado con `node --version`), así que se instaló `esbuild` y `typescript` vía `npx`/`npm install --no-save` (sin tocar el proyecto, solo en `/tmp`) para comprobar de verdad:
  - **`esbuild` (parseo real de sintaxis)**: las 4 funciones parsean sin ningún error — cero errores de sintaxis en TypeScript real, no una suposición.
  - **`tsc --noEmit` (chequeo de tipos real)**: solo salieron los 4 errores esperados de "implicit any" en el parámetro `req` de `serve()`, causados por no tener cargados los tipos de Deno en este chequeo aislado (no hay forma de instalar `@types/deno` sin la toolchain real de Supabase) — ningún error de lógica ni de tipos real en el código propio.
  - **Consistencia de nombres de campo cliente↔servidor**, revisada a mano para las 3 funciones de IA nuevas: `ActivityRequest`/`IcebreakerRequest`/`ScoreRequest` en Kotlin (`@SerialName("chatId")`) y las mismas en Swift (nombres de propiedad literales `chatId`/`sessionId`/`opponentId`, mismo patrón ya usado en el resto del proyecto para los campos de Postgrest — sin conversión automática a snake_case en ningún sitio) coinciden exactamente con los `interface`/`DuelRequest` de cada función TypeScript.
  Sin hallazgos que corregir — se documenta como verificación real superada, no como "sin cambios" vacío: es la primera vez que el código de las Edge Functions pasa por una herramienta real en toda la sesión, un paso más real hacia "listo para lanzar".

- **RONDA DE MAYOR IMPACTO DE TODA LA SESIÓN**: se descubrió que este entorno, aunque nunca ha podido instalar Postgres nativo ni Docker (límite real, confirmado muchas veces), SÍ tiene Node (`v24.15.0`) — y `@electric-sql/pglite` empaqueta Postgres real (no un simulador) compilado a WASM, instalable vía `npm install` sin permisos de administrador. Esto permite, por primera vez en toda la sesión, ejecutar las migraciones reales contra un motor de base de datos de verdad.
  - Construido `supabase/local_verify/` (nuevo, permanente en el repo): `run_migrations.mjs` aplica las 35 migraciones en orden real, con un stub mínimo de lo que Supabase provee y PGlite no trae de fábrica (roles `anon`/`authenticated`/`service_role`, `auth.users`/`auth.uid()`/`auth.role()`, `storage.buckets`/`storage.objects`/`storage.foldername()`). Primer intento: 18/35 (fallos por huecos del propio stub — falta `schema private`, roles, `storage.buckets.public`, `storage.foldername`). Corregidos los stubs, no las migraciones (los fallos eran del entorno de prueba, no del SQL real) → **35/35 migraciones aplican limpio**, la primera confirmación real de que 35 archivos SQL escritos a lo largo de toda la sesión son sintácticamente correctos de verdad.
  - `test_triggers.mjs` (nuevo): va más allá de "compila" — inserta/actualiza filas reales y comprueba que la LÓGICA de los triggers de seguridad de las últimas pasadas hace exactamente lo que dice que hace: **7/7 pruebas pasan** — `is_verified` no se puede autoconceder por UPDATE directo, `posts.like_count`/`comment_count` no se pueden inflar por UPDATE directo pero SÍ suben correctamente vía INSERT real en `likes`, `chats.compatibility_score` no se puede escribir directo pero SÍ sube correctamente vía INSERT real en `compatibility_votes`, y `event_attendees.social_count` se incrementa de verdad para ambas partes cuando un social se acepta dentro de un evento activo.
  - Documentado en `supabase/local_verify/README.md` con honestidad explícita sobre los límites (no es un proyecto Supabase completo — sin RLS real de PostgREST, sin GoTrue/Storage/Realtime reales) y enlazado desde `supabase/DEPLOYMENT.md` (nuevo paso "1.5. Verificar las migraciones ANTES de tocar un proyecto real"). Corregido el lenguaje "sin Postgres local instalable" en la sección "Estado real por plataforma" de este mismo archivo, que llevaba toda la sesión siendo repetido sin matizar que "nativo" y "real" no son lo mismo.
  - `node_modules`/`package-lock.json` de esta carpeta añadidos a `.gitignore` (dependencia real instalada vía npm, no se versiona).
  Esto no resuelve el bloqueo de probar contra un proyecto Supabase real (sigue documentado, sigue siendo el paso pendiente para cualquier verificación de extremo a extremo con RLS/Auth/Storage reales) — pero cierra la brecha más grande y más repetida de honestidad técnica de toda la sesión: de "nunca verificado, solo razonado" a "verificado de verdad contra Postgres real, con datos reales".

- Ampliación directa del hallazgo de la pasada anterior (PGlite = Postgres real): construido `test_rls.mjs` (nuevo, en `supabase/local_verify/`), un escalón más fuerte que `test_triggers.mjs` — aquel probaba triggers (se disparan sin importar quién ejecuta la sentencia), este prueba RLS de verdad, que SÍ depende de quién eres. Requirió dos piezas que `test_triggers.mjs` no necesitaba:
  1. `auth.uid()`/`auth.role()` dejan de devolver un valor fijo — ahora leen de `current_setting('app.uid'/'app.role', true)`, el mismo mecanismo de GUC de sesión que usa Supabase de verdad (con el JWT), simplificado a una variable de texto que la prueba puede cambiar por usuario.
  2. `grantSupabaseDefaults()`: PGlite/Postgres puro no concede privilegios a nivel de tabla a `anon`/`authenticated` — eso lo hace Supabase automáticamente al crear un proyecto, fuera de cualquier migración de usuario. Sin replicar ese `grant`, ninguna prueba llegaría siquiera a evaluar RLS (Postgres deniega antes, por falta de privilegio).
  Con `SET ROLE authenticated` real + un `auth.uid()` distinto por prueba, se verificaron **11/11** políticas de bloqueo y RLS reales, con dos usuarios de verdad, no simulados: `messages_insert` (sin bloqueo escribe, con bloqueo NO), `message_reactions_insert`, `compatibility_votes_insert`, `compat_requests_insert` (los 4 con el mismo patrón bloqueo→denegado), `duels_insert` (revocado por completo, ni el propio cliente puede insertar tras 0035), `socials_update` (solo el destinatario real puede aceptar — encontrado y corregido un fallo en la propia prueba, no en el código: un UPDATE bloqueado por RLS no lanza excepción, afecta 0 filas en silencio, hay que comprobar el resultado en vez de esperar un throw), y la cascada real de borrado de cuenta (`delete from auth.users` sí arrastra `profiles`/`chats`/`socials`, la primera vez que se confirma con un DELETE real en vez de solo leer `on delete cascade` en el SQL).
  `package.json`/`README.md` actualizados (`npm run rls`), `DEPLOYMENT.md` menciona el nuevo paso. Con estas dos herramientas juntas, la seguridad de este proyecto (bloqueo, columnas protegidas, cascadas) pasó de "razonada y revisada" a "probada con Postgres real, cambiando de rol de verdad" — el salto de honestidad técnica más grande de toda la sesión, en dos pasadas consecutivas.

- Ampliación de `test_rls.mjs` (misma familia, más cobertura real): 6 pruebas nuevas, todas pasan (17/17 en total). `posts_select`/`profile_sections_select`: un tercero sin ninguna relación (`u3`, nunca visto antes) NO ve un post "solo socials" ni una sección de perfil privada, pero el social ya aceptado de verdad (`u1`↔`u2`) SÍ los ve — primera vez que se prueba la regla "solo socials" con RLS real, no solo lectura del SQL. `likes_insert_own` (0012): confirmado con datos reales que alguien bloqueado no puede dar like al post de quien lo bloqueó. `event_attendees_insert_own` (0030, el fix de fraude de ranking de hace unas pasadas): intentar unirse a un evento con `social_count = 999` falla de verdad por RLS, y con `social_count = 0` (el valor real) funciona — cierra el círculo de ese hallazgo con verificación real, no solo la migración aplicando limpio. Build Android recompilado para confirmar que el cambio (solo Node/SQL) no lo afectó: BUILD SUCCESSFUL.

- Ronda mixta: vuelta al barrido de bloqueo (mismo patrón de muchas pasadas atrás) + una prueba real más en `test_rls.mjs`.
  1-2. **Historias nunca filtraba historias de gente bloqueada** — mismo hallazgo de privacidad ya cerrado en Home/Match/Find/Search/ChatList/Guardados/Tus socials, esta pantalla se había quedado fuera. Corregido en `StoriesViewModel.kt`/`.swift`.
  3. `test_rls.mjs`: añadida una prueba real más (18/18 ahora) — `follows_delete` (0026, el hallazgo más severo de esa pasada: "dejar de seguir" llevaba desde su construcción sin política de borrado) confirmado con un DELETE real, no solo con la migración aplicando limpio.
  Build Android recompilado: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 2353, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda de hallazgos reales sobre notificaciones/sesión, familia nueva (no bloqueo, no SQL): 5 arreglos reales esta pasada, todos encontrados auditando el ciclo de vida de las notificaciones locales construidas hace unas pasadas.
  1-2. **iOS: badge del icono nunca se sincronizaba**. Se pedía permiso `.badge` (`requestAuthorization`) pero nunca se rellenaba — comparado con WhatsApp/Instagram/Gmail, el número rojo del icono nunca aparecía de verdad. Corregido centralizando la sincronización en un `didSet` de `unreadCount` (`NotificationsBadgeViewModel.swift`, `UNUserNotificationCenter.setBadgeCount`), que cubre tanto el contador optimista al llegar un aviso como la recarga tras marcar como leído — antes solo se habría cubierto el primer caso si se hubiera puesto `content.badge` a mano, dejando el segundo caso desincronizado igual.
  3-4. **Cerrar sesión no limpiaba notificaciones de la cuenta anterior**: en ninguna plataforma se limpiaban las notificaciones entregadas/el badge al cerrar sesión — un usuario distinto that inicie sesión en el mismo dispositivo vería avisos ajenos hasta el próximo evento de Realtime. Corregido en `AppRootView.swift` (reactivo a `authStateChanges`: sesión pasa a nil → `setBadgeCount(0)` + limpiar pendientes/entregadas) y en `AppRoot.kt` (reactivo a `sessionStatus`: `NotAuthenticated` → `NotificationManagerCompat.cancelAll()`).
  5. **Fuga real de canal Realtime en iOS**: `RootTabView.swift` nunca llamaba a `notificationsBadge.stop()` al desaparecer (cerrar sesión) — a diferencia de Android (`RootTabView.kt` ya lo hacía bien desde su construcción, `DisposableEffect { onDispose { badgeVm.stop() } }`), el canal de la cuenta cerrada se quedaba sin darse de baja explícitamente. Corregido con `.onDisappear`, mismo patrón que `AvisosView.swift`/`ChatView.swift` ya usaban.
  Build Android recompilado tras los cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 3332, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande: primera pieza real de panel de moderación, uno de los huecos grandes documentados desde hace muchas pasadas en "Pendiente real" — `reports` tenía RLS y recibía denuncias reales desde el principio, pero nadie podía leerlas nunca sin una clave privilegiada directa contra la base de datos.
  1. **`0036_admin_moderation.sql`**: `profiles.is_admin` (misma familia exacta que `is_verified`, 0029 — protegida por trigger, nunca autoconcedible por el cliente, solo `service_role` puede tocarla) + `reports_select_admin`/`reports_update_admin` (un admin real puede leer y resolver denuncias; el denunciante sigue sin poder releer las suyas, decisión de producto ya tomada, no un descuido). **36/36 migraciones siguen aplicando limpio contra Postgres real.**
  2. `test_rls.mjs` ampliado a 22/22: confirmado con RLS real que un usuario normal no ve ninguna denuncia, que un admin de verdad sí las ve y puede marcarlas como revisadas, y que `is_admin` no se puede autoconceder (revertido por el trigger). De paso, se encontró y corrigió un fallo real en el propio arnés de pruebas: `auth.role()` nunca reflejaba el cambio de rol (`asSuperuser()`/`asUser()` no fijaban `app.role`, así que toda escritura "de confianza" se habría revertido igual que las no confiables) — corregido antes de confiar en el resultado.
  3-4. `ModerationScreen.kt`/`ModerationView.swift` (nuevas): lista de denuncias abiertas con "Marcar revisada"/"Descartar", visibles solo si `profiles.is_admin` es de verdad `true` para el usuario actual — comprobado con una consulta real, no un flag local. Enlazadas desde Ajustes (Android: botón condicional en `AjustesScreen.kt`/`RootTabView.kt`; iOS: `NavigationLink` condicional en `AjustesView.swift`). **Android: COMPILADO Y VERIFICADO EN EJECUCIÓN** (emulador arrancado desde cero, reinstalado, relanzado, PID 2372, sin FATAL en logcat; emulador y daemon de Gradle cerrados de nuevo al terminar). iOS sin verificación de compilador real.
  No es un panel de moderación completo (sin filtros, sin historial de resueltas, sin ver el perfil denunciado desde la propia pantalla) — es la base real (esquema protegido + lectura/escritura real) más el caso de uso mínimo, documentado con honestidad como primera pieza, no la pieza entera.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 arreglos esta pasada, dos familias — cerrar un hueco real de usabilidad en la Moderación recién construida, y una pasada de "contador de caracteres" comparando con Instagram/Twitter.
  1-2. **Hallazgo real en Moderación (construida la pasada anterior)**: `ModerationScreen.kt`/`ModerationView.swift` mostraban razón/detalles de una denuncia pero nunca quién denunció a quién — inútil para un moderador de verdad. Corregido resolviendo `reporter_id`/`reported_id` a nombres reales (mismo patrón sin join embebido/FK ambigua ya usado en `DuelHistoryViewModel`/`SocialsListViewModel`, porque `reports` también tiene dos columnas que referencian `profiles`).
  3-6. **Contador de caracteres real, mismo criterio en 3 campos × 2 plataformas**: los límites de `posts.caption` (2200) y `profiles.display_name`/`bio` (50/300) son reales desde hace varias pasadas y ya se validan antes de guardar, pero nada avisaba mientras se escribe — comparado con Instagram/Twitter, que siempre muestran el contador restante. Añadido en `NewPostSheet.kt`/`NewPostView.swift` y `EditProfileSheet.kt`/`EditProfileView.swift`, en rojo al pasarse del límite.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL (dos veces, verificando cada mitad de la ronda por separado). **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 2981, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): 6 arreglos esta pasada, cerrando el barrido de "contador de caracteres" (empezado la pasada anterior) y una familia nueva de consistencia (analítica de eventos clave).
  1-4. Contador de caracteres real añadido en los 2 campos que faltaban de esa familia (denuncias, 1000; secciones de perfil, 2000), en ambas plataformas: `ReportSheet.kt`/`SafetyToolbar.swift` y `PerfilScreen.kt`/`PerfilView.swift`. Deliberadamente NO añadido al compositor de chat ni al de comentarios — son campos inline con botón de enviar al lado (mismo patrón que WhatsApp/Telegram, que tampoco muestran contador ahí), distintos de un formulario tipo bio/caption donde sí es la norma (Instagram/Twitter).
  5-6. **Hallazgo real de consistencia**: cada acción clave de la app se registra con `AnalyticsManager` (`duel_completed`, `tab_view`, `app_open`...) salvo denunciar y resolver una denuncia — el propio equipo de SOCIAL no tendría forma de saber si la función de denuncias (o la Moderación recién construida) se usan de verdad sin entrar a la tabla a mano. Añadido `track("report_submitted")` en `SafetyManager.kt/.swift.report()` y `track("report_$status")` en `ModerationScreen.kt`/`ModerationView.swift.setStatus()`.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 3130, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): auditoría completa de `AnalyticsManager.track()` en toda la app (grep de todas las llamadas existentes: `invisible_toggled`, `social_sent`, `duel_completed`, `event_joined`, `app_open`, `report_submitted`/`report_$status` de la pasada anterior, `social_accepted`, `tab_view`) — encontrados 3 huecos reales, los más importantes de cualquier embudo de producto social, sin ninguno de los dos: **registrarse** y **publicar** (post o historia) nunca se registraban.
  1-2. `track("post_created")` en `NewPostViewModel.kt`/`.swift` — publicar es la acción de activación más básica del feed.
  3-4. `track("signup_completed")` en `AuthViewModel.kt`/`.swift` — el primer paso de cualquier embudo, ausente por completo.
  5-6. `track("story_created")` en `StoriesViewModel.kt`/`.swift`.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 2385, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): continuación directa de la auditoría de `AnalyticsManager` de la pasada anterior — quedaban 3 acciones reales más sin registrar, dos de ellas señales genuinas de confianza y seguridad, no solo de producto.
  1-2. `track("user_followed")` en `FollowManager.kt`/`.swift`.
  3-4. `track("comment_added")` en `CommentsViewModel.kt`/`.swift`.
  5-6. `track("block_created")` en `SafetyManager.kt`/`.swift` — junto con `report_submitted` de la pasada anterior, cierra las dos métricas de confianza y seguridad más básicas que el propio equipo de SOCIAL necesitaría para saber si esas funciones se usan de verdad.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 3144, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): tercera pasada seguida cerrando huecos de `AnalyticsManager` — el más importante de los tres encontrados hoy es una métrica de participación básica que llevaba toda la sesión sin registrarse.
  1-2. **`track("signin_completed")`** en `AuthViewModel.kt`/`.swift` — `signup_completed` se registraba (pasada anterior) pero volver a iniciar sesión, la métrica de participación recurrente más básica de cualquier app, no se registraba en absoluto.
  3-4. `track("duel_started")` en `DuelViewModel.kt`/`.swift` — solo se registraba `duel_completed`; sin el evento de inicio es imposible medir cuánta gente empieza un duelo y lo abandona antes de terminarlo.
  5-6. `track("user_unfollowed")` en `FollowManager.kt`/`.swift` — se registraba `user_followed` (pasada anterior) pero no su opuesto.
  Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 2930, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda grande (mínimo 6 arreglos por pasada, instrucción explícita del usuario): cuarta y probablemente última pasada seguida cerrando huecos de `AnalyticsManager` — las señales de participación más frecuentes de un feed (like, guardar) y el otro paso de embudo de Match (pedir compatibilidad) seguían sin registrarse.
  1-2. `track("post_liked")` en `HomeViewModel.kt`/`.swift` — solo en la dirección de "dar like", mismo criterio que el resto de eventos de una sola dirección (report_submitted, user_followed).
  3-4. `track("post_saved")` en `HomeViewModel.kt`/`.swift`.
  5-6. `track("compat_request_sent")` en `MatchViewModel.kt`/`.swift`.
  Con esto, la cobertura de `AnalyticsManager` pasa a incluir los 3 embudos completos de la app (registro→login, feed→like/guardar/publicar, match→compatibilidad/duelo) más las 2 métricas de confianza y seguridad (denunciar, bloquear) — auditoría de esta familia dada por cerrada salvo que aparezca un hallazgo nuevo real. Build Android recompilado tras los 6 cambios: BUILD SUCCESSFUL. **Verificado en ejecución real**: emulador arrancado desde cero, reinstalado, relanzado, PID 2830, sin FATAL en logcat. Emulador y daemon de Gradle cerrados de nuevo al terminar.

- Ronda distinta a las últimas (auditoría de producto contra `growth_strategy.md`, no analítica): esa estrategia dice explícitamente que la métrica que de verdad importa es la "densidad efectiva" (sección 6) y que "un usuario que prueba la función estrella y no funciona no vuelve a abrir la app" (sección 5) — releída con ese criterio, se encontraron 3 hallazgos reales en Modo Evento, la cuña de entrada que la propia estrategia identifica como la más importante.
  1-2. **La densidad ("X personas aquí ahora") ya se calculaba (`ranking` se cargaba desde `checkForNearbyEvent`, incluso antes de unirse) pero nada en la UI la mostraba hasta después de unirse al evento** — justo lo contrario de "el valor tiene que sentirse en los primeros 30 segundos". Añadido en `EventModeScreen.kt`/`EventModeView.swift`, visible de inmediato.
  3. **Hallazgo de fiabilidad real, solo Android**: `checkForNearbyEvent` se llamaba UNA SOLA VEZ al abrir la cámara, con `getLastKnownLocation` (puede ser nulo o desactualizado) — si el usuario abría la app antes de llegar al recinto, Modo Evento no se activaba nunca en toda la sesión, ni acercándose después. iOS ya no tenía este problema (`EventLocationProvider` usa `startUpdatingLocation()`, continuo de verdad) — confirmado revisando el código real antes de "arreglar" algo que ya estaba bien. Corregido en Android con un bucle de reintento cada 30s mientras la cámara está abierta.
  4-5. **El hallazgo más grande de esta pasada**: `event_density()` (0005_analytics.sql) — la función SQL que calcula exactamente la métrica que la estrategia dice que más importa (% de asistentes con la app activa en los últimos 15 min) — llevaba muchas pasadas construida y correcta, pero NADA la llamaba nunca, ni un panel de organizador ni la propia pantalla de evento, solo aparecía citada en comentarios. Primera llamada RPC de todo el proyecto (`postgrest.rpc()`) — firma verificada decompilando el `.aar` real de `postgrest-kt` antes de escribir el código (mismo criterio que `broadcast`/`track` en pasadas anteriores). Un primer intento falló en compilación real (`rpc` sin resolver — la función de extensión necesita su propio import, no basta con el de la clase), corregido y reverificado.
  6. Mostrada la densidad real en `EventModeScreen.kt` ("🔥 X% activos ahora mismo"), junto al número bruto de asistentes — más informativa, porque distingue quién sigue realmente ahí ahora de quién solo se unió en algún momento.
  **Android: COMPILADO Y VERIFICADO EN EJECUCIÓN.** iOS con el fix de UI (1-2), sin el de densidad RPC (4-6, no aplicado a iOS esta pasada — mismo hallazgo real pendiente para una pasada futura) ni verificación de compilador real.

- **Pasada 2026-08-24, la más grande de la sesión hasta ahora — backend real conectado + tienda de avatares 3D + rediseño visual completo pedido por el usuario a partir de un prompt de diseño detallado.**
  1. **Backend real conectado por primera vez**: usuario dio URL + clave publishable de un proyecto Supabase real (`yzxzsaprvtsavkuhqfao`, eu-west-1). `local.properties` actualizado (gitignored). 39 migraciones aplicadas directamente vía conexión Postgres (pooler `aws-1-eu-west-1.pooler.supabase.com:5432`, NO el host directo `db.*.supabase.co` que solo resuelve IPv6 y falla desde este entorno). Registro/login end-to-end probados de verdad en el emulador.
  2. **Bug crítico real encontrado y corregido EN PRODUCCIÓN**: `admin_ban_user()` (0037, pasada anterior) nunca funcionó de verdad contra Supabase real — el simulador local (`test_rls.mjs`) usa su propia convención (`app.role` vía `set_config`) para simular roles, que Supabase real NO lee (`auth.role()` real lee `request.jwt.claim.role`, confirmado consultando `pg_proc` directamente). La función "funcionaba" en local sin funcionar en producción — el hallazgo más serio de honestidad técnica de la sesión: el arnés de pruebas daba un falso positivo. Señal real verificada empíricamente: dentro de una función `security definer` propiedad de `postgres`, `current_user = 'postgres'` sin importar qué rol llamó — nadie puede falsificar esto. Corregido en `0039_fix_definer_elevation.sql`, aplicado a producción, y **reverificado con usuarios reales creados por SQL** (`verify_remote_ban.mjs`): baneo confirmado funcionando de verdad.
  3. **Tienda de avatares 3D** (`0038_avatar3d_store.sql`, con el patrón de elevación correcto desde el principio): `avatar_items` (categoría/gratis-pago/precio), `profile_owned_items`, `profile_avatar_selections` (RLS: solo se puede seleccionar una pieza gratis o ya comprada), `purchase_avatar_item()` (descuenta monedas de forma atómica, comprueba precio server-side), `profiles.coins` protegida por trigger.
  4. **Motor de visor 3D real integrado**: SceneView 2.3.0 (open source, Compose-nativo, sobre Google Filament — sin SDKs de pago como Ready Player Me, decisión explícita tras pedirlo el usuario). Modelos reales descargados (con permiso del usuario, automatizado vía la API de itch.io tras extraer manualmente el token de descarga — checkout "paga lo que quieras" con clic humano, no automatizable del todo): Quaternius Universal Base Characters (CC0, licencia verificada: uso comercial permitido, sin atribución), 2 cuerpos + 8 piezas de pelo/cejas/barba, ~46MB en `assets/models/`.
  5. **PENDIENTE REAL, diagnóstico ampliado en la pasada siguiente (mismo día), aún sin resolver**: el modelo de CUERPO (`Superhero_Female_FullBody.gltf`) crashea Filament de verdad — `SIGABRT` nativo, "At least one buffer slot was never assigned to an attribute" (error de construcción de VertexBuffer en gltfio, antes de cualquier llamada a GPU). Las piezas de pelo (sin esqueleto/rigging) cargan SIN crashear, con o sin luz, con la variante "Rigged to Head Bone" o la variante "Origin at 0" (sin rigging, centrada en el origen — probada específicamente para descartar un offset de hueso como causa). Se descartaron por orden, cada una probada de verdad en el emulador: (a) rigging/esqueleto — descartado, el pelo sin rigging también sale negro; (b) offset de posición del hueso de cabeza — descartado, la variante centrada en origen también sale negro; (c) falta de luz — descartado, con `rememberMainLightNode` añadido sigue en negro; (d) el visor dentro de un `Dialog` (ventana Android separada, problema conocido de `SurfaceView` en diálogos) — descartado, renderizado inline (sin Dialog) también sale negro. Filament inicializa limpio en logcat en todos los casos, sin ningún error/warning de gltfio ni excepción Kotlin. **Sospecha fundamentada, no confirmable en este entorno**: incompatibilidad conocida y documentada de SwiftShader (renderizador OpenGL ES por software que usa este emulador, sin aceleración GPU real) con el pipeline PBR de Filament — necesitaría un dispositivo/emulador con GPU real para confirmar si es eso o algo más. Punto de entrada de prueba temporal en `AjustesScreen.kt` ("🧪 Ver avatar 3D (prueba)", ahora renderizado inline, no en Dialog) — no es la integración final, solo para verificar el motor.
  6. **Rediseño visual pedido explícitamente por el usuario a partir de un prompt de diseño detallado** (paleta exacta, tipografía, layout de 6 pantallas — SOCIAL/Home/Match/Avisos/Perfil/Chat): como los 6 archivos HTML de maqueta que el prompt exigía leer no existían en el proyecto, se construyeron los 6 (`social_boceto.html`, `home_boceto.html`, `match_boceto.html`, `notificaciones_boceto.html`, `perfil_boceto.html`, `SOCIAL_APP.html`) fielmente a partir de la especificación de texto (colores exactos, tamaños, disposición) para tener una referencia real y visualizable en vez de trabajar solo de memoria. Aplicado a Android: logo real (`social_logo.png` del usuario) en vez de texto "SOCIAL"; tema pasado de oscuro (heredaba `Theme.Material.NoActionBar`, fondo `#0E0E12`) a claro con los colores reales del logo; pantalla de bienvenida nueva (Crear cuenta / Iniciar sesión) antes del formulario, que antes no existía.
  7. **Bug real de navegación encontrado probando en el emulador**: el `Row` de accesos rápidos del Perfil (Duelos/Chats/Publicaciones/Socials/Guardados/Ajustes) no tenía `horizontalScroll` — con 6 accesos, "Ajustes" quedaba literalmente empujado fuera de la pantalla, imposible de tocar por ningún medio normal. Corregido con `Modifier.horizontalScroll(rememberScrollState())`.
  8. Checkbox de términos en el registro corregido: `Alignment.CenterVertically` centraba el checkbox respecto a las DOS líneas de texto (aceptación + enlaces), no solo la primera — pedido explícito del usuario, corregido con `Alignment.Top` + padding compensatorio.
  **Android: COMPILADO en cada paso. Verificado en ejecución real en el emulador para: registro/login contra Supabase real, navegación de Ajustes ya arreglada, botón de prueba del avatar 3D (sin crash con pelo, SÍ crash con cuerpo — ambos resultados confirmados en logcat real, no supuestos).** iOS sin ningún cambio de esta pasada aplicado ni verificado.

- **Continuación misma tarde (2026-08-24)**: usuario pidió parar el mecanismo de `/loop` (wakeups programados) y seguir trabajando directamente en el turno. 4 hallazgos/arreglos reales más.
  1. **Diagnóstico ampliado del avatar 3D en negro** (ver punto 5 de la entrada anterior): se descartaron sistemáticamente rigging, offset de hueso, falta de luz, y renderizado dentro de un `Dialog` — los cuatro probados de verdad en el emulador, ninguno era la causa. Sospecha fundamentada y no resuelta: incompatibilidad conocida de SwiftShader (renderizador por software del emulador) con el pipeline PBR de Filament — no confirmable sin GPU real. Detenido el diagnóstico ciego en este punto, honesto sobre el límite del entorno en vez de seguir adivinando sin poder verificar.
  2. **Docstring falso encontrado y corregido en `HomeScreen.kt`**: afirmaba "Historias sigue sin implementar en ninguna plataforma" cuando `StoriesBar()` ya estaba construido y montado (línea 123 del mismo archivo) — mismo patrón de deshonestidad de comentarios ya encontrado varias veces esta sesión, esta vez en un archivo que no se había revisado antes con ese criterio.
  3. **Cabecera de Home rediseñada** con la identidad de marca real: antes texto plano "Home" + dos `TextButton` de texto ("🔍 Buscar", "🗺 Find"); ahora botón "F" cuadrado con degradado azul→morado real (abre Find, misma función que antes), logo real `social_logo.png` centrado, icono de búsqueda a la derecha (misma función real que antes, sin perder nada). Primera pantalla además de Auth en recibir el rediseño visual de esta sesión.
  **Android: COMPILADO y VERIFICADO EN EJECUCIÓN** (emulador arrancado desde cero, reinstalado, relanzado, PID 3260, cabecera de Home confirmada visualmente por captura real). Emulador y daemon de Gradle cerrados de nuevo al terminar.

- **Ronda 2026-08-24 (continuación de la tarde, tras parar el `/loop`)**: 2 familias de hallazgos reales — un bug de privacidad/producto grande (Find/"Cerca" nunca tuvo datos reales que mostrar) y el redisenio fiel de Match a partir de match_boceto.html, con sus 4 chips convertidos en filtros/orden reales en vez de decorativos. De propina, diagnóstico y arreglo de la causa real de los ANR repetidos de esta sesión.
  1. **Hallazgo real, mismo nivel que el bug de `admin_ban_user` de la pasada anterior**: `profiles.last_lat`/`last_lng` existen en 0001_schema.sql desde el principio, y `FindLocationsViewModel.kt`/`.swift` ("Find", el botón "F" de Home) ya las leía correctamente filtrando por `location_public`/bloqueados/invisible — pero NADA en ninguna plataforma escribía nunca esas columnas. El interruptor de "Ubicación pública" en Ajustes llevaba pasadas enteras guardando el booleano sin que "Find" pudiera mostrar jamás una sola ubicación real. Corregido en `PrivacySettingsViewModel.kt`/`.swift.publishCurrentLocation()`: al activar el interruptor, se publica la última ubicación conocida una vez (no rastreo continuo en segundo plano — decisión de alcance explícita, documentada en el propio código). Android reutiliza el mismo `LocationManager` de plataforma ya usado en Modo Evento (sin dependencia nueva); iOS usa un `CLLocationManager` de una sola petición (`requestLocation()`).
  2. **Redisenio de Match fiel a match_boceto.html** (`MatchScreen.kt`/`MatchView.swift`): título "🔍 Match", buscador real (filtra por nombre/intereses), 4 chips de filtro, tarjetas 2 columnas con degradado de fondo, avatar en círculo blanco arriba-izquierda, badge de compatibilidad arriba-derecha (verde si es pública, translúcido "?%"/"Solicitado" si no — los 3 estados reales se conservan, no solo el "?%" fijo del mockup), nombre con sombra abajo-izquierda. A diferencia del mockup (chips decorativos), aquí los 4 filtran/ordenan sobre datos reales: "Compatibles" por % descendente, "Tus gustos" por solapamiento real de intereses (`MatchViewModel.myInterests`, antes se calculaba y se tiraba), "Nuevos" por `profiles.created_at` (campo añadido a `Profile`/`Profile.swift`, no existía en el modelo aunque sí en la tabla), y "Cerca" por distancia real usando el fix del punto 1.
  3. **Causa real de los ANR "System UI isn't responding" de toda esta sesión, encontrada por accidente verificando este mismo redisenio**: 4 procesos `find.exe` huérfanos de comandos `find /` sin acotar de tareas MUY anteriores de esta sesión (uno llevaba corriendo desde el 22/08, dos días) seguían vivos en segundo plano, escaneando el disco entero del host sin límite y saturando su CPU al 100% de forma continua — el host de 2 núcleos físicos nunca se documentó como "insuficiente en general", sino que llevaba días con una fuga real de procesos huérfanos. Matados con `taskkill`/`Stop-Process`. Confirmado con `Get-CimInstance Win32_Process` antes de matarlos (con `CommandLine` real, no una suposición). **Verificado en ejecución real, con matices**: `:app:compileDebugKotlin` y `:app:assembleDebug` — BUILD SUCCESSFUL ambos, dos veces. App instalada y lanzada 3 veces en el emulador (`social_light`), confirmada en primer plano y activa vía `dumpsys activity` (`topResumedActivity=...com.social.app/.MainActivity`), sin ningún FATAL/AndroidRuntime en logcat en ningún intento. **No se consiguió una captura de pantalla limpia de la pestaña Match en sí**: incluso después de matar los `find.exe` huérfanos y reiniciar SystemUI, el emulador siguió entrando en un bucle de ANR de SystemUI — con el host todavía al 100% por el propio entorno de desarrollo (VSCode + el proceso de esta sesión), no por el emulador ni por nuestra app. Documentado con honestidad: el código compila limpio y la app corre sin crashear, pero la verificación visual interactiva de Match quedó bloqueada por el estado del host en este momento concreto, no por un bug de la implementación. Emulador y daemon de Gradle cerrados al terminar.
  **iOS sin verificación de compilador real** (no hay Mac en este entorno) — `PrivacySettingsViewModel.swift`, `MatchView.swift`, `MatchViewModel.swift` y `Models.swift` escritos siguiendo exactamente el mismo patrón ya verificado en Android, con un único punto de riesgo real señalado en el propio código: el `Button` de "?% · Pedir" anidado dentro de la `label` de un `NavigationLink` es el mismo patrón que ya usaba `MatchCell` antes de este redisenio (no es riesgo nuevo introducido hoy).

- **Ronda 2026-08-24, la más significativa para iOS de toda la sesión: primer compilador real de Xcode, encontrado vía GitHub Actions (runner macOS), tras pedirlo el usuario explícitamente ("busca la manera de probar iphone").** Sin Mac disponible en este entorno de desarrollo, todo el código Swift de la sesión se había escrito "razonado por analogía" con la versión Kotlin equivalente, documentado honestamente como "sin verificación de compilador real" cientos de veces — este hallazgo confirma que ese riesgo era real, no solo teórico.
  1. **Repositorio subido a GitHub** (público, decisión explícita del usuario tras preguntarle): `github.com/asscervera-gif/social-app`. `.gitignore` ya protegía `local.properties`/`Config.plist` — verificado antes de subir que ningún script de `supabase/local_verify/` tenía la contraseña real de la base de datos hardcodeada (todos la reciben por `process.argv`, ninguno la tiene en el propio archivo).
  2. **`.github/workflows/build.yml`** (ya existía como esqueleto de una pasada anterior, nunca ejecutado hasta ahora): compila con `xcodebuild` de verdad en un runner `macos-14`, genera un `Config.plist` de credenciales de relleno (no reales) para que la app pueda arrancar en CI, lanza en el Simulador de iOS y sube una captura de pantalla real como artefacto — sin necesidad de Mac propio ni cuenta de Apple Developer de pago (decisión explícita del usuario: solo compilador + Simulador, no dispositivo físico).
  3. **15 rounds reales de iterar contra el compilador real, cada uno con un fallo real distinto, hasta el primer `BUILD SUCCESSFUL`** — el hallazgo más grande y valioso de honestidad técnica de toda la sesión, mayor incluso que el bug de `admin_ban_user` de hace unas pasadas, porque no era un bug puntual sino una categoría entera de riesgo (código nunca compilado) que llevaba toda la sesión señalándose como límite del entorno:
     - **XcodeGen generaba un `.pbxproj` en formato de proyecto 77 ("future Xcode project file format")** — no por la versión de Xcode activa (ya era 15.4), sino porque XcodeGen fija ese formato en su propio binario. Corregido seleccionando dinámicamente la versión de Xcode MÁS RECIENTE instalada en el runner antes de generar.
     - **`.select(columns: "...")` en 12 sitios de 10 archivos** — la firma real de `PostgrestQueryBuilder.select()` en supabase-swift no lleva la etiqueta `columns:` (confirmado leyendo `Sources/PostgREST/PostgrestQueryBuilder.swift` real en GitHub). Sin este fix, la app iOS entera no compilaba — un hallazgo invisible durante TODA la sesión.
     - **`functions.invoke(...)` en 3 sitios no tiene ningún overload que devuelva `Data`** — solo `invoke<T: Decodable>(...) -> T` (decodifica directo) e `invoke(...) -> Void` (descarta el cuerpo). Confirmado leyendo `Sources/Functions/FunctionsClient.swift` real. Corregido usando el overload genérico directamente, sin `JSONDecoder` manual.
     - 6 hallazgos más en un solo lote: `switch` sobre `Bool?` con `case true/false/nil` no es exhaustivo para el comprobador de Swift; `setBadgeCount(0)` es `async throws` sin `try/await`; `.foregroundStyle(.accentColor)` busca un miembro inexistente en el protocolo `ShapeStyle` (usar `Color.accentColor`); `ChangePasswordView.swift` sin `import Supabase` (`UserAttributes` no se encontraba); mutación de una propiedad `@MainActor` desde un `Task.detached` sin saltar de actor de verdad; **la superficie real de Presence en supabase-swift** (`track(state:)` con etiqueta, `[String: PresenceV2]` no `[String: Presence]`) confirmada leyendo `Sources/RealtimeV2/` real — el propio código ya avisaba con un "aviso de honestidad más fuerte de lo habitual" de que este era el sitio de mayor riesgo de toda la sesión, y en efecto lo era.
     - `client` fuera de alcance en `ProfileViewerView.swift` (declarado dentro de un `do { }`, usado fuera).
     - `.buttonStyle(cond ? .bordered : .borderedProminent)` no compila — un ternario exige que ambas ramas sean el mismo tipo concreto, y son dos `ButtonStyle` opacos distintos.
  4. **Diagnóstico serio de una captura de pantalla que seguía mostrando la pantalla de inicio de iOS** en vez de la app, ya con el build compilando limpio — se descartaron por orden, cada uno con evidencia real (no suposición): timing insuficiente (descartado subiendo la espera), relanzar dos veces (era contraproducente — interrumpía la transición a primer plano, confirmado leyendo el log real del sistema con `xcrun simctl spawn log show`, que mostró `SpringBoard`: `visibility: Foreground`, `Window did become application key`). La causa real, encontrada en el mismo log completo: la app SÍ llegaba a primer plano y ENTONCES caía con el `fatalError` real de `SupabaseManager.swift:42` ("No se pudo leer 'SUPABASE_URL' de Config.plist") — el `Config.plist` de relleno se generaba DESPUÉS de `xcodegen generate`, y como el recurso está marcado `optional: true` en `project.yml`, XcodeGen solo lo referencia en el proyecto si el archivo ya existe en el momento de generar. Reordenado.
  5. **Resultado final: `BUILD SUCCESSFUL` real, app instalada y lanzada en el Simulador de iOS, captura de pantalla real subida como artefacto de CI — la pantalla de registro (`AuthView.swift`) renderiza correctamente de verdad**, primera confirmación visual real de iOS en toda la sesión. (Nota: esa pantalla es el diseño anterior al rediseño visual de boceto que sí se aplicó a Android esta sesión — el rediseño de iOS sigue pendiente, ver "Pendiente real".)
  **El workflow queda funcionando de verdad en `main` — cada futuro `git push` compilará y capturará pantalla automáticamente, cerrando de forma permanente (no solo para esta pasada) el hueco de "iOS sin verificación de compilador real" que se venía señalando desde el principio de la sesión.**

- **Ronda 2026-08-24 (noche), primer redisenio visual de iOS verificado con captura real**: con el CI ya funcionando, se empezó a llevar a iOS el mismo redisenio de marca que Android tiene desde hace una pasada — Auth/Welcome primero, con verificación visual real en cada paso (no solo "compila").
  1. **`Social/Assets.xcassets` nuevo** (antes el proyecto no tenía ningún catálogo de assets): `AccentColor` (rosa/coral #FF5A76, mismo valor que Android) y `social_logo` (mismo PNG que usa Android). XcodeGen detecta `.xcassets` automáticamente dentro de `sources:`, sin tocar `project.yml` para eso.
  2. **`AuthView.swift`**: `WelcomeView` nueva antes del formulario (logo real + eslogan + "Crear cuenta"/"Ya tengo cuenta"), mismo patrón que `WelcomeScreen` en `AuthScreen.kt` — antes entraba directo a un formulario de 6 campos.
  3. **`HomeView.swift`**: cabecera de marca real (botón "F" en degradado azul→morado → abre Find, logo, buscar), mismo patrón que `HomeScreen.kt`. "Nuevo post" pasa de icono en la barra de navegación a botón flotante (equivalente del `FloatingActionButton` de Android). Corregido de paso el mismo docstring falso sobre Historias que ya se había corregido en Android.
  4. **2 hallazgos reales más, encontrados por la propia captura de pantalla real** (no hipótesis — el CI ya permite esto):
     - Añadir el primer `.xcassets` del proyecto activó una comprobación de Xcode que antes ni se ejecutaba: **"None of the input catalogs contained a matching ... app icon set named 'AppIcon'"** — build roto. Un icono de app real (1024×1024, sin transparencia, diseño propio) es trabajo aparte; se desactivó explícitamente (`ASSETCATALOG_COMPILER_APPICON_NAME: ""`) en vez de fabricar uno de baja calidad solo para pasar el build. Documentado como pendiente real de diseño.
     - **La primera captura mostró el botón "Crear cuenta" en azul del sistema, no en rosa de marca**, pese a que `AccentColor` ya existía en el catálogo — un proyecto generado con XcodeGen (a diferencia de uno creado desde el asistente de Xcode) no fija automáticamente el tinte global desde `AccentColor`; hace falta el build setting `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` explícito. Corregido y **reverificado con una segunda captura real que confirma el rosa de marca aplicado de verdad** en el botón y en los enlaces.
  **Verificado con captura de pantalla real de Auth/Welcome (2 veces: antes y después del fix de color).** La cabecera de Home compiló limpio (mismo `BUILD SUCCESSFUL` de la sesión) pero **no se pudo verificar visualmente con captura real** — el `Config.plist` de CI usa credenciales de relleno que nunca llegan a autenticar, así que el flujo de captura del CI nunca llega más allá de Auth/Welcome. Verificar Home/Match/etc. visualmente en iOS necesitaría o un dispositivo/Mac real, o un bypass de autenticación exclusivo de CI (no construido — más ingeniería de la que pide una verificación visual puntual). Documentado como límite real del enfoque de CI, no una función a medias.

- **Ronda 2026-08-24/25 (madrugada, dentro de `/loop`), el hallazgo real más grave de todo el trabajo de CI**: el usuario pidió ver la interfaz interior real de iOS (no solo Auth/Welcome), lo que llevó a descubrir un bug crítico de permisos que habría fallado igual en un dispositivo físico real, no solo en CI.
  1. **Bypass exclusivo de CI en `AppRootView.swift`** (`CI_SKIP_AUTH`, activado solo vía `SIMCTL_CHILD_CI_SKIP_AUTH=1` desde el workflow — no hay forma de activarlo desde fuera de un lanzamiento de CI controlado): salta la comprobación de sesión real para poder capturar `RootTabView` (la app real, pestaña "Social"/cámara por defecto) en vez de quedarse siempre en Auth/Welcome, ya que el `Config.plist` de relleno de CI nunca consigue una sesión real.
  2. **Hallazgo crítico real, no solo de CI**: la primera captura con el bypass activo mostró la pantalla de inicio de iOS en vez de la app — ni timing, ni conceder permisos de antemano (`simctl privacy grant all`, probado y descartado) lo arreglaban. El log real del sistema (mismo método que ya había resuelto el bug de `Config.plist`) reveló la causa real: **"This app has crashed because it attempted to access privacy-sensitive data without a usage description... NSCameraUsageDescription"** — pese a que `Social/Info.plist` SÍ tenía escrito el texto real de permiso de cámara/ubicación/Bluetooth/etc. Causa raíz: `xcodegen generate` **escribe `Social/Info.plist` desde cero** usando SOLO las claves listadas en `project.yml` → `info.properties` (que solo tenía 3 claves genéricas: `CFBundleDisplayName`, `UILaunchScreen`, `UISupportedInterfaceOrientations`) — el archivo committeado en el repo con los 6 textos reales de permisos (`NSCameraUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription` + `NSBonjourServices`) se sobreescribía silenciosamente en cada generación, perdiendo TODAS esas claves. **Esto significa que la app llevaba construida toda la sesión con textos de permiso reales y bien escritos que probablemente NUNCA llegaron a un build real** (ni local ni CI) — un hallazgo de honestidad más grave que cualquiera de los bugs de compilador anteriores, porque el código Swift en sí era correcto; el problema estaba en la configuración de generación del proyecto. Corregido moviendo las 6 claves + `NSBonjourServices` a `project.yml` (única fuente que sobrevive a `xcodegen generate`), texto idéntico al que ya existía.
  3. **Verificado con captura real, dos veces**: primero confirmó el diálogo real de permiso de cámara apareciendo con el texto correcto en español (antes crasheaba antes de poder mostrarlo siquiera) — prueba directa de que el fix funcionó. `simctl privacy grant all` no bastaba para suprimir el diálogo en la captura automática; añadido `grant camera/microphone/bluetooth/location-always` explícitos por servicio (con `|| true` por si algún nombre de servicio no es válido en esta versión de simctl). **Captura final**: la interfaz real completa visible — cabecera "Buscando personas cerca de ti..." con icono de invisible, barra de pestañas real (Home/Match/Avisos/Perfil) con la marca ya aplicada — y un mensaje de error honesto ("No se pudo acceder a la cámara trasera") en vez de una pantalla negra o un crash, porque el runner de GitHub Actions no tiene cámara física real. Este último punto es un límite real y esperado del entorno (mismo tipo de honestidad que el hallazgo de SwiftShader/Filament en Android), no un bug — el manejo de errores de `SocialCameraView.swift` está funcionando exactamente como debe.
  **Resultado neto**: un bug de configuración de Xcode genuinamente grave (permisos silenciosamente vacíos en cualquier build real) encontrado y corregido, y confirmación visual real end-to-end de que `RootTabView`/`SocialCameraView` renderizan correctamente en iOS por primera vez en toda la sesión.

- **Ronda 2026-08-25 (dentro de `/loop`, regla: comparar contra las redes sociales grandes y construir, no solo auditar), 2 hallazgos reales nuevos, ambas plataformas**:
  1. **Onboarding real de "cómo funciona"** (`HowItWorksView.swift`/`HowItWorksScreen.kt`, nuevos): ninguna plataforma explicaba nunca qué es o cómo funciona la detección UWB antes de soltar al usuario en la cámara — comparado con cualquier app grande (Instagram/TikTok/Snapchat, que sí muestran un carrusel de bienvenida antes de la función principal), un hueco real, directamente exigido por `growth_strategy.md` ("cero fricción en el primer uso... el valor tiene que sentirse en los primeros 30 segundos"). 3 slides reales (detección UWB, apuntar con la cámara, mandar un social + modo invisible), mostrado una sola vez por dispositivo (UserDefaults/SharedPreferences local, no columna de servidor) justo tras el primer login/registro real. Evento de analítica al completarlo (`how_it_works_completed`).
  2. **Hallazgo de confianza y seguridad real, encontrado por comparación cruzada entre plataformas**: `AppRoot.kt` (Android) ya comprobaba `my_ban_status` y mostraba una `BannedScreen` real si un admin te había baneado (desde una pasada anterior) — **`AppRootView.swift` (iOS) nunca lo tuvo**. Un usuario baneado en iOS seguía usando la app con total normalidad; el baneo solo existía como una fila en la base de datos sin ningún efecto real en esa plataforma. `growth_strategy.md` llama esto explícitamente "el requisito de adopción más alto, no una función secundaria" — más grave que el hueco de onboarding. Corregido con `checkBanStatus()` (misma vista `my_ban_status`, 0037_admin_ban.sql) + `BannedView`, mismo patrón que Android.
  **Ambas plataformas verificadas de verdad**: Android compilado localmente (`BUILD SUCCESSFUL`, Gradle daemon parado al terminar); iOS compilado y verificado en el CI real de GitHub Actions (`BUILD SUCCESSFUL`).

- **Ronda 2026-08-25 (dentro de `/loop`), el hallazgo de seguridad más grave de toda la sesión — encontrado verificando la infraestructura de push, no auditando a propósito.**
  1. **CRÍTICO, ACTIVO EN PRODUCCIÓN desde `0039_fix_definer_elevation.sql`**: `protect_ban_columns()` (trigger que revierte `is_banned`/`banned_until`/`ban_reason` si no viene de `admin_ban_user`) dejó de proteger NADA en cuanto se aplicó 0039. La propia función trigger está declarada `security definer` — y una función `security definer` fija `current_user` a SU PROPIO dueño (`postgres`) durante toda su ejecución, sin importar qué rol disparó el `UPDATE` que la invocó. El chequeo que añadió 0039 (`current_user <> 'postgres'`, para distinguir "esto viene de `admin_ban_user`, de confianza" de "esto viene de un cliente directo") era por tanto **siempre falso, para cualquier llamador** — cualquier usuario autenticado podía autodesbanearse con `update profiles set is_banned = false where id = auth.uid()`, sin pasar nunca por `admin_ban_user`. Encontrado con el arnés real de pruebas (`test_rls.mjs`, nuevo caso "protect_ban_columns"), reproducido primero contra la baseline de 39 migraciones SIN tocar nada de esta pasada para confirmar que no era una regresión de hoy. `verify_remote_ban.mjs` (pasada anterior) no lo detectó porque solo probaba "`admin_ban_user` SÍ banea" (that path sigue intacto — un trigger no-op no le afecta), nunca "un usuario normal NO puede autodesbanearse", que es justo la mitad que se rompió. **Arreglado en `0042_fix_ban_protection_no_op.sql`** (quita `security definer` del trigger — no hace falta, ya tiene `REVOKE EXECUTE` de public/anon/authenticated; mismo patrón sin este problema que `protect_is_admin()`/`protect_is_verified()`, que nunca añadieron el chequeo de `current_user`). Verificado local: 33/33 tests (antes 32/33), incluido que el camino legítimo de `admin_ban_user` sigue baneando/desbaneando con normalidad. **Aplicado a producción por el usuario vía SQL Editor de Supabase** (decisión explícita: SQL dado al usuario para pegar él mismo, sin volver a compartir la contraseña de la base de datos).
  2. **Infraestructura real de push (APNs + FCM)**, primera pieza del hueco de infraestructura más grande documentado en "Pendiente real": `0040_device_tokens_push.sql` (tabla `device_tokens` + RLS `_own`, 5 tests nuevos en `test_rls.mjs`, verificado local), `0041_notify_push_trigger.sql` (trigger `pg_net` → Edge Function, NO verificable en PGlite — `pg_net` no existe ahí, documentado como límite real del harness, no un bug), y `supabase/functions/send-push/index.ts` (envía a APNs con JWT ES256 firmado vía Web Crypto, y a FCM con la API legacy — sin Deno real disponible en este entorno para probarlo en ejecución, mismo criterio de honestidad que duel-ai/icebreaker-ai).
  3. **Cliente que faltaba en AMBAS plataformas** — hasta este punto la tabla/trigger/función existían pero ningún cliente escribía nunca una fila real en `device_tokens`. **iOS**: `PushTokenManager.swift` + `AppDelegate.swift` (`@UIApplicationDelegateAdaptor`, ya que la `App` de SwiftUI no expone `didRegisterForRemoteNotificationsWithDeviceToken` directamente) + entitlement `aps-environment`/`UIBackgroundModes` en `project.yml` — **verificado con el CI real de GitHub Actions, `BUILD SUCCESSFUL`**, incluido el entitlement nuevo (el punto de mayor riesgo de romper el pipeline de 15 rounds, confirmado que no lo rompió). **Android**: `PushTokenManager.kt` + `SocialFirebaseMessagingService.kt` + permiso `POST_NOTIFICATIONS` vía `rememberLauncherForActivityResult` en `AppRoot.kt` + plugin `google-services` aplicado SOLO si existe `app/google-services.json` (para no romper builds sin credenciales reales) — **verificado con `:app:compileDebugKotlin` real, BUILD SUCCESSFUL**, Gradle BoM 34.18.0 y plugin 4.4.4 confirmados como versiones publicadas reales (no adivinadas) vía Maven Central/GitHub. Bug real encontrado y corregido en el camino: un comentario XML nuevo en `AndroidManifest.xml` usaba `--` (ASCII), que XML prohíbe dentro de comentarios — rompía `processDebugMainManifest`; corregido al em-dash `—` que ya usa el resto del archivo.
  **Pendiente real de despliegue** (no de código, ver "Pendiente real" arriba): proyecto Firebase + `google-services.json`, clave `.p8`/cuenta Apple Developer de pago, y los secrets de Supabase — sin eso, la infraestructura entera compila y corre pero no envía push de verdad todavía.

- **Ronda 2026-08-25 (dentro de `/loop`, cadencia real de 1 min vía cron), paginación hacia atrás en el chat**: `loadHistory()` (ambas plataformas) llevaba desde una pasada anterior limitado a los últimos 100 mensajes, con "paginar hacia atrás no se construye aquí" documentado explícitamente como hueco real — un chat con más de 100 mensajes perdía silenciosamente todo lo anterior, sin forma de volver a verlo, a diferencia de cualquier app grande. Construido `loadOlderMessages()`/`hasMoreHistory`/`isLoadingOlder` en ambas plataformas: pide la página de 50 mensajes justo antes del más antiguo ya cargado (`lt("created_at", oldest)`, primer uso de ese operador en todo el proyecto) y la antepone a la lista; botón "Cargar mensajes anteriores" al principio de la lista, solo visible mientras queda más historial. **Android: COMPILADO OK** (`:app:compileDebugKotlin`, confirma que `lt()` existe de verdad en el DSL de postgrest-kt — no se había usado antes en el proyecto). **iOS**: mismo patrón con `.lt("created_at", value:)`, firma confirmada leyendo `PostgrestFilterBuilder.swift`/`PostgrestFilterValue.swift` reales en GitHub (`Date` sí conforma `PostgrestFilterValue`, se codifica como ISO8601) antes de escribirlo — verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), tocar un aviso local no llevaba a ningún sitio -- hallazgo comparando con Instagram/TikTok/Snapchat**: el texto de la notificación decía "Toca para verlo" en Android (LocalNotifier.kt) pero sin `PendingIntent` no pasaba nada al tocarla; en iOS el hueco era mayor -- sin `UNUserNotificationCenterDelegate` registrado, iOS ni siquiera PRESENTA un aviso local mientras la app está en primer plano (comportamiento por defecto del sistema sin delegado), y el `content.body` nunca se rellenaba (solo título, sin ninguna llamada a la acción).
  - **Android**: `PendingIntent` real hacia `MainActivity` con extra `EXTRA_OPEN_TAB="avisos"` en `LocalNotifier.kt`; `MainActivity.onNewIntent()` (la Activity ya suele estar en memoria) actualiza un `mutableStateOf` que `AppRoot`/`RootTabView` reciben como `startTab` y navegan una vez a la pestaña Avisos. **COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: `NotificationDelegate.swift` (nuevo) implementa `willPresent` (banner/sonido/badge también en primer plano, antes invisible) y `didReceive response:` (postea `.openAvisosTab` vía `NotificationCenter` si `userInfo["open_tab"] == "avisos"`), registrado en `AppDelegate.application(didFinishLaunchingWithOptions:)`. `NotificationsBadgeViewModel.swift` ahora rellena `content.body`/`content.userInfo`; `RootTabView.swift` escucha `.onReceive(...)` y cambia `selectedTab`. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), el feed principal nunca mostraba QUIÉN publicó cada post -- el hallazgo más grande de esta tanda, comparado con Instagram/TikTok/Twitter/Facebook**: la tarjeta de `PostCard` (ambas plataformas) mostraba imagen, caption, fecha y los iconos de like/comentar/compartir/guardar/denunciar, pero nunca el nombre ni el avatar de quien publicó, ni ninguna forma de tocar para ver su perfil -- la ÚNICA pantalla con listado de toda la app sin `onOpenProfile` (Search/Match/Avisos sí lo tienen, confirmado en `RootTabView.kt`). Esto también explica por qué los comentarios (`CommentsSheet.kt`) tampoco muestran autor -- mismo hueco raíz, pendiente para una ronda futura, documentado aquí y no arreglado en esta pasada para no mezclar dos áreas en un mismo commit.
  - Ambas plataformas: `posts` no lleva el perfil embebido, así que se resuelve con un solo select adicional por los `author_id`/`authorID` distintos del feed ya cargado (no N+1) -- `authorProfiles: Map<String, Profile>`/`[UUID: Profile]` nuevo en `HomeViewModel`. Cabecera con avatar+nombre tocable al principio de cada `PostCard`, navega al perfil (mismo patrón `onOpenProfile`/`NavigationLink { ProfileViewerView(...) }` ya usado en el resto de la app).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`) -- confirma que `isIn()` existe de verdad en el DSL de postgrest-kt, primer uso en el proyecto.
  - **iOS**: `.in("id", values:)`, firma confirmada leyendo `PostgrestFilterBuilder.swift` real en GitHub antes de escribirlo. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), cierre del hueco gemelo dejado pendiente en la ronda anterior: los comentarios tampoco mostraban autor**: mismo hallazgo y mismo arreglo que el feed (`HomeViewModel.authorProfiles`), aplicado ahora a `CommentsViewModel`/`CommentsSheet.kt`/`CommentsView.swift` -- avatar+nombre tocable por comentario, navega al perfil. Caso límite cubierto en ambas plataformas: si es el primer comentario propio en un post, el propio perfil todavía no estaba en el mapa (solo se cargaba el de quienes ya habían comentado) -- se resuelve aparte tras publicar, sin esperar a la próxima recarga.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`) -- bug real encontrado y corregido en el camino: faltaba el import de `clickable` en `CommentsSheet.kt`.
  - **iOS**: `NavigationLink` dentro del propio `NavigationStack` de `CommentsView` (se presenta como `.sheet` — patrón distinto pero equivalente al "cerrar hoja y navegar" de Android, ambos llevan al mismo `ProfileViewerView`). Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), mismo hueco de "listado sin autor/imagen" también en Guardados/Tus publicaciones**: siguiendo la misma auditoría que encontró el feed y los comentarios sin autor, `SavedPostsScreen`/`SavedPostsView` (posts de CUALQUIER autor guardados) tenían el mismo hueco -- ni imagen, ni nombre, ni forma de tocar para ver el perfil, comparado con la colección "Guardado" real de Instagram. `MyPostsScreen`/`MyPostsView` (siempre tus propios posts, así que el autor no aporta nada) compartían el hueco más simple: tampoco mostraban la imagen, solo texto.
  - Guardados: mismo patrón `authorProfiles` ya establecido (select adicional por `author_id` distintos), avatar+nombre tocable → perfil, más render de `mediaUrl`/`mediaURL` (Coil/AsyncImage, mismo patrón que `PostCard`).
  - Tus publicaciones: solo la imagen (el autor sería siempre "tú", redundante).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: mismo patrón `.in("id", values:)` + `NavigationLink`/`AsyncImage`. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), "Tus chats" sin avatar -- comparado con WhatsApp/Instagram/Messenger**: `ChatListEntry` solo llevaba `otherName`, nunca el avatar de la otra persona -- el identificador visual principal de cualquier lista de conversaciones, algo que ninguna app de mensajería grande omite. Añadido `otherAvatarConfig` a la misma consulta ya existente (`display_name,avatar_config` en vez de solo `display_name` -- sin query nueva), avatar de 44dp/pt a la izquierda del nombre en ambas plataformas.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: mismo patrón, `NameRow` ampliado con `avatar_config`. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), mismo hueco de "listado sin avatar" también en el historial de duelos**: `DuelHistoryEntry` resolvía el nombre del rival con una consulta aparte (`display_name` por id, mismo patrón que la lista de chats) pero nunca su avatar. Añadido `opponentAvatarConfig` a la misma consulta ya existente (sin query nueva), avatar de 40dp/pt junto al nombre en ambas plataformas.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: mismo patrón. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), Avisos sin avatar del actor -- comparado con la pestaña "Actividad" de Instagram**: `NotificationRow`/la fila de `AvisosView` solo mostraban un icono/emoji genérico por tipo de aviso (social/follow/fight/like/compat_request), nunca el avatar de QUIÉN lo disparó -- Instagram/TikTok siempre muestran la foto de perfil del actor como elemento visual principal de cada fila de actividad. `payload["actor_id"]` ya existía en cada aviso (usado para las acciones de la hoja), así que se resuelve con un batch-fetch de perfiles por los actor_id distintos de la página cargada, más una resolución individual para cada aviso nuevo que llega por Realtime.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: mismo patrón (`payload["actor_id"]` como String, convertido a `UUID` con `UUID(uuidString:)`). Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), cierre de la familia "listado sin avatar": "Tus socials" (la relación central de la app) tampoco mostraba avatar**: mismo patrón que feed/comentarios/chats/duelos/avisos, aplicado ahora a `SocialsListViewModel`/`SocialsListScreen.kt`/`SocialsListView.swift` -- se amplía la misma consulta ya existente (`display_name,avatar_config` en vez de solo `display_name`, sin query nueva), avatar junto al nombre en ambas plataformas. Con esto se cierra la auditoría de esta familia de hallazgos: feed, comentarios, guardados/tus publicaciones, lista de chats, historial de duelos, avisos y socials ya muestran avatar de forma consistente en toda la app.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: mismo patrón. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), el mapa "Find" no llevaba a ningún perfil al tocar un marcador -- comparado con Snapchat Map/BeReal**: `PublicLocation` ya llevaba el `id` real del perfil (necesario para `Identifiable`), pero ningún marcador estaba conectado a `onOpenProfile` -- tocar un pin solo mostraba el nombre en una burbuja, sin forma de ver el perfil completo de esa persona.
  - **Android**: `marker.relatedObject`/`marker.setOnMarkerClickListener` (osmdroid, primer uso en el proyecto) abre el perfil. **COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: el `MapAnnotation` pasa a ser un `Button`, presenta `ProfileViewerView` con el mismo patrón `Binding(get:set:)` ya usado en `HomeView.swift` para un opcional no-`Identifiable` (`.sheet(item:)` exige `Identifiable`, `UUID` no lo es). Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), "Recomendados" en Home tampoco llevaba a ningún perfil -- comparado con "Sugeridos para ti" de Instagram**: mismo hueco raíz que el feed principal, en un sitio distinto (la fila horizontal de `RecommendedCard`, no las publicaciones). Tocar una tarjeta recomendada no hacía nada en ninguna plataforma.
  - **Android**: `RecommendedCard` gana `onClick`/`Modifier.clickable`. **COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: `RecommendedCard` envuelta en `NavigationLink { ProfileViewerView(...) }`, mismo patrón ya usado en `MatchView.swift`. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), visor de imagen a pantalla completa -- comparado con Instagram/Twitter/WhatsApp**: ninguna imagen de la app (feed, chat) se podía tocar para verla a tamaño completo, solo el recorte fijo de la miniatura (220dp/pt en el feed, 200dp/pt en el chat). Visor mínimo nuevo, alcance deliberadamente acotado (sin zoom/pinch): fondo negro, imagen ajustada a pantalla, tocar para cerrar.
  - **Android**: `FullScreenImageViewer.kt` (nuevo, `util/`), reutilizado desde `PostCard` (feed) y el mensaje-imagen del chat. En el chat, la burbuja ya tenía `combinedClickable` compartido (toque = selector de reacciones, mantener pulsado = borrar) para texto/imagen/audio -- la imagen gana su propio `combinedClickable` más específico (toque = pantalla completa, mantener pulsado = borrar sigue igual), sin tocar el comportamiento de los mensajes de texto. **COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: `FullScreenImageView.swift` (nuevo, `Util/`), mismo patrón -- en el chat, el `.onTapGesture` de la imagen (más específico) sustituye al de la burbuja compartida solo para ese caso. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), cierre definitivo de la familia "listado sin avatar/tocable": el ranking de Modo Evento tampoco mostraba avatar ni dejaba tocar para ver el perfil**: mismo hueco raíz que feed/comentarios/chats/duelos/avisos/socials, esta vez en `EventModeBanner`/`EventModeView.swift` (la cuña de entrada real del producto, ver `growth_strategy.md` sección 2).
  - **Android**: se amplía la misma consulta embebida ya existente (`profiles(display_name,avatar_config)` en vez de solo `display_name`, sin query nueva) + `onOpenProfile` enhebrado `RootTabView` → `SocialCameraScreen` (nuevo parámetro) → `EventModeBanner`. **COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: ya traía el `Profile` completo embebido (`profiles(*)`), solo faltaba usar `avatarConfig`; sin `NavigationStack` ambiente en esta pantalla (todo se presenta con `.sheet`, como `SendSocialSheet`), mismo patrón `Binding(get:set:)` + `.sheet` ya usado en `FindMapView.swift`. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), apelación real de baneo -- comparado con Instagram/TikTok/Facebook, ligado directamente a growth_strategy.md sección 5 ("seguridad percibida... la confianza es el requisito de adopción más alto")**: `BannedScreen`/`BannedView` ya mostraba el motivo real del baneo (ronda `/loop` anterior) pero no ofrecía NINGUNA forma de apelar la decisión -- un baneo equivocado (denuncia falsa, error de moderación) era definitivo sin recurso.
  - **`0043_ban_appeals.sql`** (nuevo): tabla `ban_appeals` + RLS, mismo patrón exacto ya verificado en `0036_admin_moderation.sql` para `reports` (el propio usuario inserta/lee SU apelación, un admin real lee/resuelve todas). Un usuario baneado sigue teniendo una sesión de Auth válida (el baneo no revoca el JWT), así que puede insertar su apelación con normalidad. **Verificado local: 38/38 tests** (`test_rls.mjs` contra un directorio temporal sin `0041`/pg_net, mismo criterio ya establecido — 6 casos nuevos: insertar a nombre de otro falla, insertar la propia funciona, solo el dueño y un admin la ven -- RLS real, no filtro de cliente -- y un admin puede marcarla revisada).
  - **Cliente (ambas plataformas)**: `BannedScreen`/`BannedView` gana un formulario real (comprueba si ya existe una apelación al entrar, para no duplicar) que inserta en `ban_appeals`. `ModerationScreen`/`ModerationView` gana una sección "Apelaciones de baneo" con "Desbanear" (llama a `admin_ban_user` con `p_banned=false`, mismo RPC que ya usaba "Banear" desde denuncias en Android) y "Descartar".
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`).
  - **iOS**: primer uso de `.rpc()` en toda la plataforma iOS de este proyecto -- firma confirmada leyendo `SupabaseClient.swift`/`PostgrestClient.swift` reales en GitHub antes de escribirla (`client.rpc(_:params:) throws -> PostgrestFilterBuilder`, expuesto directo en `SupabaseClient`, no tras `.postgrest` como en Kotlin). Verificación final pendiente del CI real de GitHub Actions en este push.
  - **Hallazgo nuevo, separado, documentado para una ronda futura (NO arreglado aquí para no mezclar dos áreas)**: `ModerationView.swift` nunca tuvo el botón "Banear" que sí existe en `ModerationScreen.kt` desde hace varias pasadas -- un admin en iOS puede leer/descartar denuncias pero no banear directamente desde ahí, solo un hallazgo de paridad entre plataformas, no relacionado con las apelaciones.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), cierre del hallazgo de paridad documentado en la ronda anterior: iOS no podía banear directamente desde una denuncia**: `ModerationScreen.kt` (Android) tiene el botón "Banear" desde hace varias pasadas (0037_admin_ban.sql); `ModerationView.swift` nunca lo tuvo -- un admin en iOS podía leer y descartar denuncias, pero no tenía ninguna acción real contra el usuario denunciado. `banReportedUser()` (nuevo) reutiliza el mismo `BanParams`/`.rpc("admin_ban_user", params:)` ya verificado la ronda anterior para la apelación de baneo. Solo iOS -- Android ya lo tenía, sin cambios ahí. Verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), última pantalla de la familia "listado sin avatar/tocable": "Quién ve tu compatibilidad"**: mismo hueco raíz que feed/comentarios/chats/duelos/avisos/socials/evento -- `CompatSharesScreen`/`CompatSharesView.swift` (revocar a quién le has concedido tu % de compatibilidad) tampoco mostraba avatar ni dejaba tocar para ver el perfil de quien lo pidió.
  - Se amplía la misma consulta ya existente en ambas plataformas (`display_name,avatar_config` en vez de solo `display_name`, sin query nueva) + `onOpenProfile` enhebrado `RootTabView` → `CompatSharesScreen` (nuevo parámetro) en Android / `NavigationLink` en iOS.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - Con esto queda cerrada por completo la auditoría de esta familia de hallazgos en toda la app (feed, comentarios, guardados/tus publicaciones, lista de chats, historial de duelos, avisos, socials, ranking de evento, y ahora compat shares).

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), el visor de perfil de otra persona solo tenía "Seguir" -- comparado con Instagram/Twitter/TikTok**: sin "Bloquear" ni "Denunciar" directo, pese a que `ReportSheet` (ambas plataformas) ya incluye las dos acciones reales. El overlay global (`SafetyToolbar`) tiene un bug ya documentado en su propio comentario desde hace pasadas: sin un target real en contexto, denuncia por defecto al PROPIO usuario -- `ProfileViewerScreen`/`ProfileViewerView` sí tiene un target real (`profileId`/`profileID`), el sitio correcto para esta acción, y no se había aprovechado.
  - Botón "⚠" junto a "Seguir/Siguiendo" que abre `ReportSheet` con el `reportedId` real -- una sola hoja, dos acciones (denunciar y bloquear), reutilizando la UI ya construida, sin duplicar nada.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real, no arreglado aquí (bug preexistente, no introducido hoy)**: `SafetyToolbar` (overlay global de la pestaña Social) sigue denunciando al propio usuario por defecto sin un coordinador de navegación compartido entre pestañas -- documentado desde hace pasadas en el propio código, ahora con un camino alternativo correcto (este) para el caso más común (perfil de otra persona).

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), no se podía denunciar/bloquear DESDE el propio chat -- comparado con Instagram/Twitter/WhatsApp, justo donde ocurre la mayoría del acoso real**: `ChatViewModel`/`ChatView.swift` ya tenían `opponentId`/`opponentID` real en contexto (usado para "Retar a duelo"), pero ningún botón abría `ReportSheet` con ese target -- la única forma de denunciar a alguien con quien ya estabas chateando era salir del chat y buscar otro camino.
  - Icono "⚠" junto al porcentaje de compatibilidad, abre `ReportSheet` con `reportedId`/`reportedID` = el oponente real del chat -- misma hoja ya construida (denuncia + bloqueo), sin duplicar nada.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), cierre del "Pendiente real" documentado en la ronda del visor de perfil: bug de seguridad genuino en los botones de denuncia globales sin target real**: `SafetyToolbar` (overlay visible en Home/Match/Avisos/Perfil) y el icono de aviso propio de `SocialCameraScreen.kt` (Android) abrían `ReportSheet` con `reportedId` = el PROPIO usuario por defecto, al no tener ningún target real en contexto -- dos toques bastaban para denunciarse o **bloquearse a uno mismo** por accidente. No era solo cosmético: `SafetyManager.block()` inserta una fila real en `blocks`.
  - Ahora que el resto de la app ya tiene entradas de denuncia/bloqueo con target real (perfil, chat, post, comentario -- todas construidas en rondas recientes de este mismo `/loop`), estos dos botones genéricos dejan de abrir un `ReportSheet` sin sentido y en su lugar muestran una explicación real (`AlertDialog`/`.alert`) de dónde denunciar de verdad -- sin perder el icono como recordatorio visual de "seguridad primero", sin ningún riesgo de autodenuncia/autobloqueo silencioso.
  - **iOS**: solo `SafetyToolbar.swift` tenía el bug -- `SocialCameraView.swift` nunca lo tuvo (su único `ReportSheet` ya usa un `targetID` real de un peer tocado), una divergencia real entre plataformas que ya no existe tras este fix.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), ocultar una conversación de "Tus chats" -- comparado con WhatsApp/Instagram/Messenger**: `chats` no tenía ninguna política de delete ni ninguna forma de quitar una conversación de la lista. Un borrado real de la fila no encaja (es compartida entre dos personas; borrarla de verdad se llevaría los mensajes de la OTRA persona sin su consentimiento). `0044_chats_hide.sql` (nuevo): dos columnas booleanas (`hidden_by_a`/`hidden_by_b`), protegidas por trigger (mismo patrón `current_user <> 'postgres'` ya corregido en 0042, no `security definer` en el trigger de protección en sí) para que cada quien solo pueda ocultar SU PROPIA copia; un mensaje nuevo real las restaura solas vía un segundo trigger (sí `security definer`, a propósito, mismo mecanismo que `admin_ban_user` usa para saltarse la protección de forma legítima) -- un chat oculto para siempre en cuanto llega actividad real sería peor que no tener la función.
  - **Hallazgo real de robustez del arnés de pruebas local, no de producción, encontrado y resuelto a fondo (no rodeado)**: el primer intento de `auth.uid()` bajo un rol no-superusuario en una sesión de PGlite falla con "permission denied for schema auth" (el arnés nunca concede `usage on schema auth` a `authenticated`/`anon`, a diferencia de un proyecto Supabase real, que sí lo hace por defecto) -- pero solo la PRIMERA vez que esa expresión concreta se evalúa en la sesión; una vez un rol CON permiso (superuser/service_role, que ignora ACLs) la ejecuta con éxito una vez, invocaciones posteriores bajo cualquier rol reutilizan ese plan sin volver a comprobar permisos (confirmado con pruebas aisladas mínimas, aislando el efecto de `SET ROLE`, de disparar el trigger real, y de "calentar" la expresión primero). Aislado con precisión antes de tocar nada: se descartó por orden que fuera un problema de la RLS en sí (una política SÍ lo sufre igual en un repro mínimo), del contexto de trigger (un trigger real mínimo también lo sufre) y de la tabla concreta (una tabla nueva desde cero también lo sufre) -- la única variable real es "¿ya se evaluó esta expresión con éxito antes en esta sesión, con cualquier rol?". Arreglado reordenando el `AND` del trigger de protección para que `(select auth.uid())` se evalúe ANTES que `current_user <> 'postgres'` (en Supabase real el orden no importa, `authenticated`/`anon` ya tienen ese `usage` por defecto) y añadiendo como primer sub-test una acción real de `service_role` (que de paso "calienta" la expresión) -- documentado con honestidad en el propio migration file como nota de robustez de pruebas, no como si fuera un bug de producción que no fue.
  - **Verificado local: 43/43 tests** (`test_rls.mjs`, 4 casos nuevos: `service_role` puede tocar cualquiera de las dos copias, u2 puede ocultar la suya, u2 NO puede ocultar la de u1 -- revertido en silencio, y un mensaje nuevo real deshace el ocultado). De paso, el test del mensaje nuevo encontró que u1 seguía bloqueado por u2 de un bloque de pruebas anterior (bloqueo real, bidireccional) -- resuelto desbloqueando primero con el mecanismo real (`blocks_delete_own`), no simulado.
  - **Cliente (ambas plataformas)**: `ChatListViewModel`/`.swift` filtran la conversación oculta para mí (columna correcta según si soy `user_a`/`user_b`) y exponen `hideChat()`. UI: mantener pulsado (Android, `combinedClickable`) / deslizar (iOS, `.swipeActions`, mismo patrón ya usado en Guardados/Socials/CompatShares) para ocultar.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real de despliegue**: `0044_chats_hide.sql` sin aplicar a producción todavía.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), cierre del visor de imagen a pantalla completa en Guardados/Tus publicaciones**: el visor construido para el feed y el chat (`FullScreenImageViewer`/`FullScreenImageView`) no se había propagado a `MyPostsScreen`/`SavedPostsScreen` (Android) ni `MyPostsView`/`SavedPostsView.swift` (iOS) -- ya mostraban la imagen desde una ronda anterior, pero seguía sin ser tocable, mismo hueco ya cerrado en otros sitios.
  - Reutilización directa del componente ya construido, sin duplicar nada: `.clickable`/`.onTapGesture` en la imagen, visor renderizado al final de cada pantalla.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), referencia real al contenido denunciado -- comparado con Instagram/TikTok/Facebook**: cuando una denuncia venía de un post o comentario concreto, el único rastro era un texto libre y EDITABLE por el propio denunciante ("Publicación {id}"/"Comentario {id}" metido a mano en `details`) -- un admin revisando la cola de denuncias no tenía forma real de ver el contenido, solo un ID suelto dentro de una frase que además se podía borrar o cambiar. Un hueco real de eficacia de moderación, no cosmético, encontrado auditando `ModerationScreen.kt` con el mismo criterio de honestidad de siempre.
  - **`0045_reports_content_reference.sql`** (nuevo): `reports.post_id`/`comment_id` reales (nullable, `on delete set null` -- si el contenido se borra después de denunciarse, la denuncia sigue existiendo para el historial, solo pierde la referencia). **Hallazgo de seguridad adicional encontrado en el camino, corregido en la misma migración**: sin más, esa referencia habría sido decorativa para el caso más delicado -- `posts_select`/`comments_select` solo dejan ver contenido "solo socials" al autor o a alguien con social aceptado, así que un admin revisando una denuncia sobre un desconocido se habría encontrado la fila vacía. Añadidas `posts_select_admin`/`comments_select_admin` (mismo patrón exacto que `reports_select_admin`/`ban_appeals_select_admin`: una política ADICIONAL, no una modificación de la existente -- las políticas del mismo comando se combinan con OR).
  - **Verificado local: 46/46 tests** (`test_rls.mjs`, 3 casos nuevos: un admin ve la referencia real, un admin SÍ puede revisar un post "solo socials" ajeno sin tener social con el autor -- aislando el bypass nuevo de la conexión social real ya existente --, y borrar el post después pone la referencia a null sin borrar la denuncia).
  - **Cliente (ambas plataformas)**: `SafetyManager.report()`/`ReportSheet` ganan `postId`/`commentId` reales, sustituyendo el hack de `initialDetails`; `PostCard`/`CommentsSheet` (feed/comentarios) los pasan de verdad. `ModerationScreen`/`ModerationView` resuelven y muestran el contenido real (imagen+caption del post, o el cuerpo del comentario) con un aviso honesto si ya no existe.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real de despliegue**: `0045_reports_content_reference.sql` sin aplicar a producción todavía (junto con `0043`/`0044`, ver rondas anteriores).

## Archivo de pasadas anteriores (resumido)

Las pasadas más antiguas de esta sesión (desde el arranque del toolchain Android hasta la auditoria de paridad de código que cerro justo antes de las entradas de arriba) se comprimieron aqui el 2026-08-19 para mantener este documento manejable — el registro completo, palabra por palabra, sigue disponible en el historial de la conversacion si hace falta reconstruirlo. Nada de sustancia se perdio: cada bug real encontrado y corregido esta ya en la lista numerada de "Bugs reales encontrados y corregidos esta sesion" y en "Anadido esta sesion" al principio de este archivo; cada hueco grande documentado sigue en "Pendiente real". Este resumen cubre: bootstrap completo del toolchain Android sin admin (JDK/SDK/Gradle/emulador), decenas de ciclos render+optimizar verificando la app en el emulador real sin crashes, y la larga auditoria de paridad codigo-por-codigo y documentacion-por-documentacion entre iOS y Android que encontro los bugs ya listados arriba (notifications sin productor, likes falso, EventMode sin limit, actividad sugerida hardcodeada, SafetyToolbar global faltante en Android, event_density roto, contadores de Perfil en 0 permanente en iOS, y las 4 afirmaciones falsas en la politica de privacidad/ficha de App Store).
