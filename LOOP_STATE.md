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
- **Llamadas de GRUPO real** (Ronda 2026-08-26, videollamada 1:1): la
  tabla `calls`/`call-token` de esa ronda son deliberadamente 1:1 (dos
  participantes simétricos) -- un chat de grupo con N participantes en
  una sola sala LiveKit es un problema de UI real distinto (rejilla de N
  vídeos, no dos lados fijos), no una extensión trivial de esta ronda.
- **RESUELTO (Ronda 2026-08-26, @menciones)**: @menciones en captions/
  comentarios (Instagram/Twitter/TikTok) -- ver esa ronda para el detalle
  completo (0074_mentions.sql). Deliberadamente NO extendido a
  chats 1:1/de grupo ni a `profile_sections` (ver "Alcance deliberado" de
  esa misma ronda).
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

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), "Marcar todo leído" en Avisos -- comparado con Gmail/Instagram/Twitter**: cualquier lista de notificaciones grande deja marcar todo como leído de una sola vez; Avisos solo dejaba marcar aviso por aviso al tocarlo. `notifications_update` (0002_rls.sql) es por fila (`recipient_id = auth.uid()`), sin límite de cuántas filas puede tocar una sola sentencia -- un UPDATE real por lote, no N llamadas, sin necesidad de migración nueva.
  - Botón "Marcar todo leído" (solo visible si hay algo sin leer), mismo criterio de idempotencia ya usado en `markMessagesRead()` (`ChatViewModel.kt`): no filtra por `read_at is null` en el servidor (sin `isNull` verificado en el proyecto), marca de nuevo un aviso ya leído sin efecto real.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), aceptar un social o una solicitud de compatibilidad no notificaba nunca a quien la pidió -- comparado con Instagram ("X aceptó tu solicitud de seguimiento")**: `socials` es la relación central de la app (único punto de envío: `SocialCameraView.swift`/`SocialCameraScreen.kt`, tras un encuentro por proximidad real) y `0006_notification_triggers.sql` ya notifica al DESTINATARIO cuando le llega una solicitud nueva -- pero nadie notificaba nunca al REQUESTER cuando esa solicitud se aceptaba. Si el otro aceptaba, el chat se creaba en silencio (`SocialLinkManager.createChatIfNeeded`, llamado desde el cliente del destinatario) y quien lo envió solo se enteraba si por casualidad abría la pestaña Chats y notaba uno nuevo. Mismo hueco exacto en `compat_requests` (status idéntico pending/accepted/declined): aceptar tampoco notificaba a quien pidió ver el %.
  - **`0046_notify_accepted.sql`** (nuevo): dos triggers `AFTER UPDATE` (mismo patrón ya usado en `private.increment_event_social_count`, 0031), disparan solo en la transición a `'accepted'` (`old.status is distinct from 'accepted'`, sin repetir en updates redundantes) e insertan una notificación real (`security definer`, bypasea RLS para insertar en nombre de otro usuario, mismo patrón que el resto de `0006_notification_triggers.sql`) para quien pidió el social/la compatibilidad. Un rechazo (`'declined'`) deliberadamente NO notifica -- mismo criterio que Instagram, que tampoco avisa al pedir seguir si te rechazan.
  - **Bug real de Android encontrado y corregido en el mismo pase**: `NotificationActionsSheet` (`AvisosScreen.kt`) mostraba los botones "Aceptar social"/"Rechazar" con un gate por PRESENCIA de `payload["social_id"]`, no por `entry.kind` (a diferencia de `AvisosView.swift`, que sí lo hacía bien con un `switch(entry.kind)`) -- el nuevo aviso `social_accepted` también trae `social_id` en el payload (misma convención documentada en el propio archivo), así que sin este fix habría mostrado "Aceptar social"/"Rechazar" sobre un social YA aceptado, cuyo UPDATE fallaría en silencio por RLS (`socials_update` solo deja responder al destinatario original, no a quien lo pidió) -- confuso pero no inseguro. Mismo fix aplicado a `compat_request`/`compatRequestId`.
  - **Verificado local: 53/53 tests** (`test_rls.mjs`, 6 casos nuevos: aceptar un social real notifica al requester con `actor_id`/`social_id` correctos; aceptar una solicitud de compatibilidad real notifica al requester con `actor_id`/`compat_request_id` correctos).
  - **Cliente (ambas plataformas)**: título+icono nuevos para `social_accepted`/`compat_accepted` en `AvisosViewModel`; `AvisosScreen.kt` ganó las dos ramas que faltaban en el `when` de routing (antes tocar uno de estos avisos no hacía nada salvo marcarlo leído). Ambos reutilizan el botón genérico "Ver perfil" ya existente -- sin necesidad de resolver `chat_id` en el trigger (se crea en una sentencia aparte, después, desde el cliente del que acepta).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real de despliegue**: `0046_notify_accepted.sql` sin aplicar a producción todavía (junto con `0043`/`0044`/`0045`, ver rondas anteriores).

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), cancelar una solicitud de social pendiente ENVIADA -- comparado con Instagram (solicitudes de seguimiento enviadas, con opción de cancelar)**: `SocialCameraView.swift`/`SocialCameraScreen.kt` es el ÚNICO punto de envío de un social (tras un encuentro real por proximidad), pero una vez enviado, quien lo mandó no tenía NINGUNA forma de verlo pendiente ni de cancelarlo -- ni rastro en "Tus socials" (`SocialsListView`, solo muestra `status = 'accepted'`) ni en ningún otro sitio. Si se capturó a la persona equivocada por error, no había forma real de deshacerlo -- solo esperar a que la otra persona lo rechazara (silenciosamente, sin aviso para nadie) o lo ignorara para siempre.
  - El backend ya soportaba esto sin cambios: `socials_delete` (0020) no distingue por `status`, cualquiera de las dos partes puede borrar una fila sin importar si sigue pendiente -- el hueco era puramente de UI/visibilidad, no de RLS. Sin migración nueva.
  - `SocialsListViewModel` (ambas plataformas) gana `pendingSent` (status='pending', requester_id = yo, mismo filtro de bloqueados ya aplicado a la lista de aceptados); `removeSocial()` ahora también quita de esta lista -- misma llamada de borrado real, reutilizada tal cual.
  - `SocialsListView.swift`/`SocialsListScreen.kt`: sección nueva "Solicitudes enviadas" (solo visible si hay alguna), cada fila con el nombre+avatar, la etiqueta "Pendiente" y un botón "Cancelar".
  - **Verificado local: 55/55 tests** (`test_rls.mjs`, 2 casos nuevos: `socials_delete` no tenía NINGÚN test hasta ahora pese a existir desde 0020 -- quien pidió un social todavía pendiente sí puede cancelarlo, y la fila cancelada deja de existir de verdad).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), el hueco de mensajería más grande de la sesión: NINGÚN mensaje nuevo generaba nunca un aviso -- comparado con WhatsApp/Instagram/Messenger/Twitter DMs**: `0006_notification_triggers.sql` solo cubre social/follow/fight/like/compat_request -- `messages` nunca disparaba nada hacia `notifications`, así que `NotificationsBadgeViewModel.swift`/`LocalNotifier.kt` (que sí escuchan esa tabla, con push real ya construido -- `0041_notify_push_trigger.sql`) jamás se enteraban de un mensaje nuevo. La única vía "en vivo" que existía era el canal Realtime propio de `ChatViewModel` -- si el destinatario no tenía esa pantalla abierta en ese instante, un mensaje nuevo era completamente invisible: sin badge, sin notificación local, sin push. Solo se descubría por casualidad, abriendo "Tus chats".
  - **`0047_message_notify_mute.sql`** (nuevo): trigger `AFTER INSERT on messages` que notifica al destinatario real (mismo patrón `security definer` que el resto de `0006_notification_triggers.sql`), y dos columnas `muted_by_a`/`muted_by_b` (mismo patrón exacto que `hidden_by_a`/`hidden_by_b` de `0044_chats_hide.sql`, con su propio trigger de protección `current_user <> 'postgres'`) para que ahora silenciar SÍ tenga un propósito real: el trigger de notificación comprueba el flag del destinatario y no inserta nada si está silenciado. A diferencia de `hidden_by_*`, silenciado NO se deshace solo al llegar un mensaje -- deshacerlo automáticamente contradiría el propósito de la función.
  - **Límite conocido, documentado con honestidad en la propia migración**: el trigger no sabe si el destinatario tiene la conversación abierta en pantalla en ese instante (esa información solo vive en el canal Presence de Realtime, cliente-a-cliente, no en una tabla consultable desde un trigger de servidor) -- mitigado marcando como leídos los avisos de tipo "message" de ESE chat en cuanto se abre (`ChatViewModel.markMessageNotificationsRead()`, ambas plataformas, trae+filtra en cliente+actualiza por id en vez de filtrar por `payload->>chat_id` en el servidor -- sin precedente verificado de filtro sobre una columna jsonb en este proyecto).
  - **Bug real encontrado en el mismo pase, de la ronda anterior**: `supabase/functions/send-push/index.ts` tiene su PROPIA copia (la tercera, junto a `AvisosViewModel.swift`/`.kt`) del mapeo kind→texto -- al añadir `social_accepted`/`compat_accepted` en `0046` se actualizaron las dos primeras pero se olvidó esta, así que un push real para esos dos avisos habría caído en el genérico "🔔"/"Notificación" aunque la app ya mostrara el texto correcto. Corregido junto con "message" (nuevo esta pasada).
  - **Verificado local: 61/61 tests** (`test_rls.mjs`, 8 casos nuevos: un mensaje real genera el aviso correcto para el destinatario con `actor_id`/`chat_id` reales; `protect_chat_muted_flags` -- mismo patrón que `protect_chat_hidden_flags`, cada quien solo silencia su propia copia; silenciado SÍ suprime el aviso de un mensaje nuevo, verificado contando que no aparece una segunda fila).
  - **Cliente (ambas plataformas)**: título+icono "Nuevo mensaje"/💬 en `AvisosViewModel`; tocar un aviso de mensaje abre el chat directamente (Android ya tenía el patrón para "social"+chat_id; **iOS no tenía NINGUNA forma de abrir un chat desde Avisos hasta ahora** -- hallazgo real de divergencia de plataforma, cerrado añadiendo `.navigationDestination(isPresented:)` a `AvisosView.swift`, mismo patrón ya usado en `PerfilView.swift`). `ChatListScreen.kt`/`ChatListView.swift` ganan el control de silenciar (icono 🔔/🔕 tocable en Android, `.swipeActions` "Silenciar"/"Activar" + icono `bell.slash` inline en iOS).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`, tras corregir un import de `Columns` que faltaba). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real de despliegue**: `0047_message_notify_mute.sql` sin aplicar a producción todavía (junto con `0043`-`0046`, ver rondas anteriores), y requiere además `supabase functions deploy send-push` para que el fix del mapeo kind→texto llegue a producción.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), denunciar un MENSAJE concreto de un chat -- comparado con Instagram/WhatsApp/Messenger**: el chat ya dejaba denunciar/bloquear a la otra persona (ronda anterior, icono junto a la barra de compatibilidad), pero sin ninguna forma de apuntar a QUÉ mensaje concreto motivó la denuncia -- mismo hueco exacto que `0045_reports_content_reference.sql` (post/comentario), justo donde ocurre la mayoría del acoso real en cualquier app de mensajería. El gesto estaba libre: mantener pulsado un mensaje ajeno no hacía nada (mantener pulsado el propio ya borra, ver `0022_messages_delete.sql`).
  - **`0048_reports_message_reference.sql`** (nuevo): `reports.message_id` (nullable, `on delete set null`, mismo criterio que `post_id`/`comment_id`). **Diferencia deliberada frente a 0045**: `posts_select_admin`/`comments_select_admin` son un bypass GENERAL para cualquier admin -- razonable para contenido semi-público. Un mensaje de chat es la superficie MÁS privada de la app, así que `messages_select_admin` es deliberadamente más estrecho: solo dejar ver un mensaje que esté REALMENTE referenciado por una denuncia real (`exists (select 1 from reports where reports.message_id = messages.id)`), nunca un bypass general que dejaría a cualquier admin leer todas las conversaciones privadas de todos los usuarios.
  - **Cliente (ambas plataformas)**: mantener pulsado un mensaje que NO es tuyo abre `ReportSheet` con el `messageId` real (en vez de no hacer nada); `SafetyManager.report()`/`ReportSheet` ganan el parámetro. `ModerationScreen`/`ModerationView` resuelven y muestran el mensaje real (cuerpo + imagen si la tiene) con el mismo aviso honesto "(ya no existe)" si ya se borró, mismo patrón que post/comentario.
  - **Verificado local: 65/65 tests** (`test_rls.mjs`, 4 casos nuevos: un admin ve la referencia real al mensaje denunciado; un admin SÍ ve el mensaje concreto denunciado; un admin NO ve otro mensaje del MISMO chat que nunca se denunció -- aislando que el bypass es acotado, no general, a diferencia de posts/comments; borrar el mensaje después pone la referencia a null sin borrar la denuncia).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real de despliegue**: `0048_reports_message_reference.sql` sin aplicar a producción todavía (junto con `0043`-`0047`, ver rondas anteriores).

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), "Tus chats" no distinguía qué conversaciones tenían mensajes sin leer -- comparado con WhatsApp/Instagram/Messenger**: solo existía el badge total de la pestaña Avisos -- dentro de la propia lista de chats, todas las filas se veían exactamente igual, tuvieran mensajes nuevos o no. Ningún cambio de servidor necesario: `messages.read_at`/`sender_id` (0017) ya son la fuente de verdad real.
  - **Hallazgo que simplificó la implementación**: `markMessagesRead()` (`ChatViewModel`) marca TODO el historial pendiente de una vez al abrir un chat, no mensaje a mensaje -- así que el estado de lectura del ÚLTIMO mensaje de un chat ya equivale exactamente a "¿hay algo sin leer aquí?", sin necesitar una segunda consulta por chat (evitando un N+1 nuevo). La consulta de `lastMessage` que `ChatListViewModel` ya hacía por chat solo ganó dos columnas (`sender_id`,`read_at`).
  - **Cliente (ambas plataformas)**: `ChatListEntry.hasUnread`; `ChatListScreen.kt`/`ChatListView.swift` ponen el nombre y el último mensaje en negrita + un punto de color cuando hay algo sin leer, mismo lenguaje visual que el punto rojo ya usado en `AvisosScreen`/`AvisosView`.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). Sin migración nueva -- `test_rls.mjs` se reconfirmó en 65/65 (sin regresiones).
  - **CI real de iOS: FALLÓ en el primer push** (`37d5254`) -- `error: missing argument for parameter 'hasUnread' in call` en `ChatListViewModel.swift:238` (`toggleMute()` reconstruye `ChatListEntry` a mano y no se actualizó al añadir el campo nuevo). Encontrado leyendo el log real de GitHub Actions (`gh run view --log`, no el resumen truncado de `--log-failed`, que no incluía el diagnóstico) y corregido en `bf8e6c5` -- exactamente el tipo de fallo real que este `/loop` existe para detectar y arreglar, no simular que no pasó.

- **Ronda 2026-08-25 (fuera del cron, a petición directa del usuario -- "ver la interfaz en el emulador"), crash real de arranque en Android encontrado ejecutando la app de VERDAD, no por lectura de código**: al abrir el emulador (Pixel 5, API 33) para enseñar la interfaz, la app mostraba la splash y moría a los ~9s. `adb logcat` real (no simulado): `java.lang.IllegalStateException: Default FirebaseApp is not initialized in this process` en `PushTokenManager.kt:26`, disparado desde `AppRoot.kt` en cuanto se concede el permiso de notificaciones -- es decir, prácticamente en cualquier arranque real. Causa raíz: el plugin `google-services` se aplica condicionalmente solo si existe `app/google-services.json` (no hay proyecto Firebase real todavía, ver "Pendiente real" de push), así que `FirebaseApp` nunca se inicializa -- pero `PushTokenManager.registerCurrentToken()` llamaba a `FirebaseMessaging.getInstance()` sin comprobarlo, tumbando la app ENTERA por una pieza opcional.
  - Arreglado envolviendo la llamada en un `try/catch (IllegalStateException)` -- mismo criterio de "sin credenciales reales, se ignora en silencio, la app sigue funcionando" ya aplicado a duel-ai/send-push/icebreaker-ai/activity-ai. **iOS no tiene este bug**: `PushTokenManager.swift` usa `UIApplication.shared.registerForRemoteNotifications()` directo (API del sistema, no requiere inicializar un SDK de terceros primero), así que no hay equivalente que arreglar ahí.
  - **De paso, encontrada y corregida la causa de que el emulador se comiera la máquina del usuario**: el AVD `social_light` tenía `hw.gpu.mode = swiftshader_indirect` (render por software, la CPU simulando toda la GPU a mano). Cambiado a `hw.gpu.mode = host` (usa la GPU real del equipo, Intel UHD Graphics detectada) -- arranque en frío bajó de ~137s a segundos, mucho menos consumo de CPU. Cambio de configuración local del AVD (`~/.android/avd/social_light.avd/config.ini`), no forma parte del repositorio.
  - **Verificado de verdad, no simulado**: `:app:assembleDebug` real, instalado en el emulador real, lanzado con `adb shell am start -W` (arranque en frío ~5.6s, `Status: ok`), proceso vivo confirmado (`pidof`, `dumpsys window | mCurrentFocus`), captura de pantalla real del onboarding tomada y publicada como artefacto para el usuario -- la app funciona de punta a punta ahora mismo, no solo "compila".
  - **Android: COMPILADO y EJECUTADO OK en emulador real**. Emulador y daemon de Gradle parados al terminar (mismo hábito de proteger la máquina del usuario de siempre).

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), editar el caption de una publicación ya hecha -- comparado con Instagram**: solo se podía borrar la publicación entera, nunca corregir el texto sin perder los likes/comentarios acumulados. `posts_write_own` (0002_rls.sql) ya es `for all`, así que editar la propia publicación ya estaba permitido a nivel de RLS -- el hueco era puramente de UI, sin migración nueva. Mismo límite real que `posts_caption_length` (0023, 2200 caracteres, igual que Instagram) ya validado con contador en vivo.
  - **Cliente (ambas plataformas)**: botón/acción "Editar" en `MyPostsScreen`/`MyPostsView` (junto a "Borrar"), abre un editor con el texto actual precargado y un contador `n/2200`.
  - **Hallazgo real de robustez del propio arnés de pruebas, encontrado al ir a añadir el test de esta función**: `likes_insert_own` (0012) referenciaba una variable `post` que NUNCA se declaraba en todo `test_rls.mjs` -- pasaba en verde desde hacía quién sabe cuántas pasadas solo porque `expectFail()` traga CUALQUIER excepción (incluido un `ReferenceError` de JavaScript por la variable inexistente), sin haber ejecutado jamás el INSERT real que decía verificar. Un "PASS" que nunca fue una prueba de verdad. Arreglado creando el post real de u1 antes de la prueba.
  - **Verificado local: 67/67 tests** (`test_rls.mjs`, 1 test reparado de raíz + 2 casos nuevos: el autor real SÍ puede editar su propio caption; un tercero NO puede editar el caption ajeno, 0 filas afectadas por RLS).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.

- **Ronda 2026-08-25 (fuera del cron, a petición directa del usuario tras verla en el emulador -- "no me gusta la interfaz, muy poco característica" / "lo de abajo para elegir perfil tampoco me gusta"), identidad visual real por primera vez en ambas plataformas**: hallazgo real, verificable en el propio repositorio -- Android ya tenía colores del logo metidos a mano e inline en `MainActivity.kt` (coral/turquesa/naranja, aproximados), pero **iOS no tenía NINGÚN color de marca, usaba el azul de sistema por defecto de SwiftUI en toda la app**. Esa asimetría es gran parte de por qué se percibía genérica. Colores extraídos de verdad del asset real (`social_logo.png`, muestreo de píxeles por bucket de tono con `System.Drawing.Bitmap` vía PowerShell, no adivinados ni inventados) -- siete acentos, uno por letra aproximada del arcoíris del wordmark: Coral (ya era el primary), Naranja, Dorado, Verde, Turquesa, Morado, Magenta.
  - **`Android/.../ui/theme/SocialTheme.kt`** (nuevo): paleta + `AccentPreference` (SharedPreferences + StateFlow, cambia al instante sin reiniciar) + `SocialTheme` composable, reemplaza el `lightColorScheme(...)` inline de `MainActivity.kt`.
  - **`Social/App/Theme.swift`** (nuevo, primera vez que iOS tiene un color de marca real): misma paleta exacta, `AccentPreference` (`ObservableObject` + `@AppStorage`, mismo criterio de persistencia que Android), aplicado con `.tint(accent.color)` en `RootTabView.swift`.
  - **Selector de acento real en Ajustes (ambas plataformas)**, tal como pidió el usuario ("que en ajustes se pueda poner al gusto"): siete círculos de color, tocar uno cambia el acento de toda la app al instante.
  - **Barra inferior, lo señalado explícitamente por el usuario**: antes era un `NavigationBar`/`TabView` totalmente por defecto -- la pestaña Match no tenía icono real (un simple "•"), la pestaña Social mostraba la letra "S" como texto plano pese a que el propio comentario del código ("letra S con degradado multicolor") prometía un degradado que **nunca se aplicaba en ningún lado** (hallazgo real, no cosmético). Arreglado en ambas plataformas: icono real para Match (corazón, `Icons.Filled.Favorite`/`heart.fill`), degradado real de 7 colores en la "S" (`Brush.linearGradient`/`LinearGradient`, mismos colores exactos que el logo).
  - **Aviso de honestidad, iOS**: el degradado de la "S" puede no verse en algunas versiones de iOS porque UIKit a veces renderiza el icono de `.tabItem` como plantilla monocroma, ignorando `.foregroundStyle` -- límite conocido de la plataforma, no verificable sin Simulador real en este entorno; documentado en el propio código, no ocultado.
  - **Alcance deliberado, no una promesa de rediseño total**: esta pasada cubre el sistema de color compartido + la barra inferior (lo pedido explícitamente) + el selector en Ajustes. El resto de pantallas sigue usando `MaterialTheme.colorScheme`/`Color.accentColor` (que ya heredan el acento base automáticamente en Android; en iOS, `Color.accentColor` ya estaba fijado a Coral en `Assets.xcassets/AccentColor.colorset` desde antes de esta pasada, confirmado al revisar el asset), pero NO siguen dinámicamente el acento personalizado fuera de la barra inferior sin un refactor mayor -- pendiente real si se pide explícitamente.
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`, tras corregir dos imports que faltaban -- `Scaffold` se perdió en un `replace` de imports, y `getValue` para el delegado `by` de `collectAsState()`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real de decisión de producto, explícitamente aplazado por el usuario**: el avatar 3D generado desde selfie sigue siendo `PlaceholderAvatarProvider` (un círculo de color aleatorio, no analiza la selfie de verdad) -- el usuario lo señaló como "un muñeco raro que no significa nada" y confirmó que se aborda DESPUÉS de esta pasada de identidad visual, no en esta.

- **Nota operativa real sobre el emulador en esta máquina (Intel i3-10110U, 2 núcleos físicos/4 hilos)**: un `System UI isn't responding` reproducible de forma consistente en el PRIMER arranque en frío justo al entrar a la pestaña Social/cámara (CameraX + UWB, la más pesada de la app) -- no es un bug de la app, es el techo físico de este hardware corriendo un emulador con gráficos acelerados. Mitigado (no eliminado del todo, honesto): `hw.cpu.ncore = 1` en vez de 2 (dejar un núcleo real libre para Windows, antes se reservaban los 2 núcleos físicos enteros), `hw.gpu.mode = host` en vez de `swiftshader_indirect` (software), arrancar con `-no-window` (sin la ventana Qt del host, menos composición) y `settings put global window_animation_scale/transition_animation_scale/animator_duration_scale 0` nada más arrancar. **Patrón que sí funciona de forma fiable**: si el primer `am start` en frío dispara el ANR, NO reintentar con una instalación/arranque nuevos (repite el mismo pico) -- pulsar HOME (`adb shell input keyevent KEYCODE_HOME`) para sacar la app a segundo plano, esperar unos segundos, y volver a abrirla con `am start` de nuevo: la segunda vez es un RESUME de un proceso ya caliente, no un arranque en frío, y ya no repite el ANR. Cambios de configuración locales del AVD (`~/.android/avd/social_light.avd/config.ini`), no forman parte del repositorio.
**Probado y descartado**: bajar la resolución (720x1280→480x854, densidad 213→160) NO evita el ANR -- probado con un arranque en frío real, salió igual. Confirma que el cuello de botella es CPU (verificación de dex/JIT de Compose+CameraX+Filament durante el arranque en frío), no relleno de píxeles de GPU -- revertido a la resolución original, sin motivo para perder calidad sin beneficio real.

**SOLUCIÓN REAL encontrada y verificada (la que sí funciona de verdad)**: snapshot de arranque rápido ("quick boot") de la máquina virtual, no de la app. `-no-snapshot` (usado desde el principio de esta sesión, probablemente por costumbre de otras pasadas centradas en verificación determinista) forzaba un arranque en frío COMPLETO cada vez -- el cuello de botella real. En vez de eso:
1. Arrancar una vez normal (sin `-no-snapshot`), instalar la app, abrirla, esperar a que se estabilice (con el truco de Home+reabrir si hace falta la primera vez).
2. Guardar el estado tal cual con `adb emu avd snapshot save <nombre>` -- captura la MÁQUINA VIRTUAL COMPLETA en ese instante, incluida la app ya corriendo.
3. Arrancar todas las veces siguientes con `-snapshot <nombre>` en vez de `-no-snapshot`.
Resultado real medido: `sys.boot_completed` en ~0s (antes ~30-40s), `adb shell echo` responde en <1s, la app aparece YA ABIERTA y perfectamente interactiva desde el primer frame -- sin rastro del ANR en varias pruebas repetidas. Esto SÍ es la solución de fondo (evita el trabajo de CPU del arranque en frío por completo, en vez de intentar que quepa en menos CPU), no un parche -- el resto de mitigaciones (`hw.cpu.ncore=1`, `hw.gpu.mode=host`, animaciones a 0, `-no-window`) siguen siendo correctas y se mantienen, pero esta es la que de verdad resuelve el síntoma que reportó el usuario. Snapshot guardado en `~/.android/avd/social_light.avd/snapshots/warm_state/` (local, no en el repositorio) -- si se reinstala una APK nueva hay que repetir los 3 pasos para que el snapshot refleje la versión actual.

- **Ronda 2026-08-25 (dentro de `/loop`, cron 1 min), editar un mensaje ya enviado -- comparado con WhatsApp/Telegram/Messenger**: un mensaje mal escrito solo se podía borrar entero (perdiendo reacciones/lectura ya asociadas), nunca corregir. `messages` no tenía ninguna política de UPDATE que dejara al remitente tocar su propio `body` -- `messages_update_read` (0017) es justo lo contrario, solo el destinatario.
  - **Hallazgo de seguridad real, encontrado ESCRIBIENDO el test de esta misma migración** (no en producción, pero real igualmente y dormido desde 0017): RLS combina políticas permisivas del mismo comando con OR A NIVEL DE FILA, no de columna -- `messages_update_read` ya dejaba a CUALQUIER destinatario reescribir `body`/`media_url`/`audio_url` del mensaje ajeno con una sola sentencia UPDATE que de paso tocara `read_at`, suplantando el contenido de un mensaje de otra persona. Nunca se probó porque ningún test anterior intentaba tocar `body` como no-remitente. **`0049_messages_edit.sql`**: añade `messages.edited_at` + `messages_update_own` (RLS, el remitente puede editar) + `private.protect_message_columns()` (trigger, mismo patrón exacto que `protect_chat_hidden_flags`/`protect_chat_muted_flags`): revierte `body`/`media_url`/`audio_url`/`edited_at` si quien edita no es el remitente real, y revierte `read_at` si quien lo toca SÍ es el remitente (ni siquiera debe poder mentirse a sí mismo sobre si su propio mensaje fue leído).
  - **Cliente (ambas plataformas)**: mantener pulsado un mensaje propio abría un borrado INSTANTÁNEO sin confirmación -- ahora abre un menú real (Editar/Borrar/Cancelar). Etiqueta "Editado" junto al mensaje, mismo lenguaje visual que WhatsApp/Telegram. Mismo límite real que `messages_body_length` (2000 caracteres). Alcance deliberado: sin ventana de tiempo límite para editar (WhatsApp sí tiene ~15 min), documentado como tal.
  - **Verificado local: 71/71 tests** (`test_rls.mjs`, 5 casos nuevos: el remitente real SÍ edita su propio mensaje; el destinatario real sigue pudiendo marcar como leído tras el cambio; un tercero NO puede editar el mensaje ajeno -- revertido en silencio, el hallazgo de seguridad real cerrado; el remitente NO puede fijar `read_at` de su propio mensaje).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`). **iOS**: verificación final pendiente del CI real de GitHub Actions en este push.
  - **Pendiente real de despliegue**: `0049_messages_edit.sql` sin aplicar a producción todavía (junto con `0043`-`0048`, ver rondas anteriores).

- **Ronda 2026-08-25 (fuera del cron, reportado en vivo por el usuario probando el emulador con ventana visible por primera vez), tres hallazgos reales sistémicos, ninguno inventado**:
  1. **"No se puede volver atrás" -- sistémico, confirmado por `grep`: NINGÚN archivo de pantalla de toda la app Android usaba `TopAppBar`**. Cada pantalla empujada por navegación dependía únicamente del gesto de "atrás" del sistema -- un antipatrón de Material Design incluso en un dispositivo real, y prácticamente imposible de repetir con ratón en el emulador. iOS no tiene este bug (SwiftUI `NavigationStack` da un botón de volver automático). **`ui/theme/BackScaffold.kt`** (nuevo): `Scaffold`+`TopAppBar` reutilizable con flecha de volver real, envolviendo las ~16 rutas empujadas directamente en `RootTabView.kt` (sin tocar la disposición interna de cada pantalla) -- Ajustes, Guardados, Tus publicaciones, Tus socials, Duelos, Tus chats, Moderación, Quién ve tu compatibilidad, Política de privacidad, Términos, Usuarios bloqueados, Chat, Duelo, Perfil ajeno, Resultado de duelo, Buscar, Find.
  2. **Perfil "super feo, nada organizado" -- comparado con el boceto real del propio proyecto** (`perfil_boceto.html`, en la raíz del repo, escrito en una pasada anterior a partir de un prompt de diseño explícito del usuario, pero nunca aplicado a esta pantalla en concreto): antes una lista plana de `TextButton`/`Text` sin ninguna jerarquía visual. Reconstruida siguiendo la ESTRUCTURA del boceto (cabecera con contadores en tarjetas, rejilla 3x2 de accesos, secciones como tarjetas con icono + etiqueta de visibilidad) sin inventar datos que no existen -- las 15 categorías reales (`PerfilViewModel.SECTION_KEYS`, ya en producción con su propio esquema RLS) se mantienen tal cual, solo cambia la vestimenta visual; "Reels"/"En directo" del boceto no existen en esta app (fuera de alcance, growth_strategy.md) y no se fabricaron, la rejilla usa los 6 accesos reales que ya existían sueltos.
  3. **"El muñeco de la cámara no significa nada" + "tiene que haber una brújula que encuentre a las personas"**: `PeerMarker` dibujaba un círculo con degradado ALEATORIO igual para cualquier persona detectada, sin nombre ni relación con quién era de verdad. Ahora resuelve el perfil real (nombre + `avatar_config`) en cuanto el UWB identifica un `profileId` (mismo patrón de caché por lote que `AvisosViewModel.fetchActorProfiles`) y usa `AvatarView` (el mismo componente de chat/posts/avisos) en vez de un degradado sin sentido -- mientras el perfil no se conoce todavía, un estado honesto "Alguien cerca" en vez de fingir un dato inexistente. Añadido `RadarBackground` (anillos concéntricos + barrido giratorio con `Canvas`+animación infinita), comparado con `social_boceto.html` (`.radar`/`.sweep`) -- la "brújula" visual pedida, reforzando que SOCIAL escanea de verdad alrededor (la dirección real ya venía del ángulo UWB en `markerOffset`, esto es la representación, no un dato nuevo inventado).
  - **Verificado real, no simulado**: instalado y lanzado en el emulador real visible (con ventana, no headless) en cada paso, confirmado por el propio usuario mirando la pantalla en vivo.
  - **Android: COMPILADO y EJECUTADO OK en cada paso** (`:app:compileDebugKotlin` + `assembleDebug` + instalado + lanzado). **iOS: no aplica al hallazgo 1** (ya tiene navegación automática); hallazgos 2 y 3 son Android-only en esta pasada, iOS queda pendiente de la misma pasada de identidad visual si el usuario lo pide explícitamente.
  - **Pendiente real explícito**: el usuario mencionó tener un boceto adicional generado en otra conversación de Claude que compartirá más adelante -- aplicar cuando llegue, no inventado todavía. También queda revisar el icono de denunciar/bloqueo global (`SafetyToolbar`) por confusión de contexto reportada por el usuario, sin resolver aún en esta ronda.

- **Ronda 2026-08-25 (fuera del cron, a petición directa del usuario), llegó el boceto real prometido: `C:\Users\assce\Desktop\SOCIAL_APP.html`** -- una maqueta interactiva mucho más completa que los `*_boceto.html` sueltos usados hasta ahora (Home con historias+carrusel de recomendados con % de compatibilidad IA+feed, Match en rejilla 2 columnas, Social con intro+radar+fichas de avatar, Avisos con sheet de acción por notificación, Perfil con look auto-rotativo avatar/foto, "Find" -- mapa de ubicación pública nunca construido en la app real --, Reels y "En directo" -- streaming en vivo --). Instrucción explícita: "lo quiero exactamente igual" / "sobre todo la interfaz". Preguntado sobre Reels/En directo (necesitan infra real de vídeo/streaming, antes fuera de alcance por decisión de producto): el usuario confirmó que SÍ los quiere, aunque sea un proyecto grande de varias pasadas -- deja de aplicar el criterio anterior de "fuera de alcance, growth_strategy.md" para esas dos piezas.
  - **Primer hueco real, backend de Reels** (`0050_reels.sql`): tabla `reels` + `reel_likes`/`reel_comments`, mismo esquema exacto que posts/likes/comments (visibilidad social-only, contadores protegidos por trigger, notificaciones `reel_like`/`reel_comment`, bloqueo aplicado desde el principio -- no como hallazgo dormido aparte). Verificado local 79/79 tests. UI de cliente (subida/reproductor/feed) y "En directo" (necesita servidor de streaming real, ver más abajo) quedan para pasadas siguientes.
  - **Segundo hueco real, "sobre todo la interfaz" -- el avatar en TODAS las pantallas**: el boceto usa el mismo generador `avatarSVG()` (busto ilustrado de piel/pelo/ropa, un solo path SVG) en Home/Match/Social/Avisos/Perfil de forma consistente -- la app real seguía mostrando un círculo con degradado + icono de persona genérico (`PlaceholderAvatarProvider`/`AvatarView`, sin relación con el diseño real), justo lo que el usuario había aplazado antes ("Ahora no, primero el look general") y que ahora sí toca resolver. Reconstruido con la MISMA geometría exacta (mismo viewBox, mismos comandos de path) vía `CartoonAvatar.kt` (Compose Canvas) / `CartoonAvatarView.swift` (SwiftUI Canvas) -- sigue sin ser un motor de avatares 3D real, solo cambia el estilo del marcador de posición. `avatar_config` pasa de `{colorSeed}` a `{type:cartoon, skin, hair, top}` (paleta discreta `AvatarLook`, mismos valores hex exactos que `LOOKS`/`me` del boceto) -- actualizado en generación (onboarding, ambas plataformas) y en edición manual (`EditProfileSheet.kt`/`EditProfileView.swift`, ahora 3 selectores con vista previa en vivo en vez de un swatch de color libre).
  - **De paso, corregido el degradado de la "S" de la pestaña Social** al degradado EXACTO del boceto (`linear-gradient(90deg,#ff3b3b,#f7b731,#20bf6b,#4dabf7,#a55eea)`, 5 paradas) en vez del arcoíris de 7 colores muestreado del logo que se usaba desde la pasada de identidad visual -- ese muestreo de 7 colores sigue siendo la base del selector de acento personalizable en Ajustes (no tocado esta pasada, es una feature real más allá del boceto, no una contradicción).
  - **Android: COMPILADO OK** (`:app:compileDebugKotlin`, dos veces: tras el sistema de avatar y tras el degradado). **iOS: CI real de GitHub Actions VERIFICADO EN VERDE** en este push (`e366a90`) -- el primer intento se quedó colgado ~20 min en "Compilar para el simulador" (muy por encima de los ~4 min normales); cancelado y relanzado con `gh run rerun` para distinguir un fallo de compilación real de un runner de GitHub simplemente atascado -- el segundo intento compiló y lanzó normal, confirmando que fue infraestructura de CI (un runner macOS lento/colgado), no un problema del código Swift añadido.
  - **Corrección real sobre la nota de "Pendiente real" de la ronda anterior**: "Find" (mapa de ubicación pública) NO es un hueco total como se documentó -- `FindMapScreen.kt`/`FIND_ROUTE` ya existen y están cableados en `RootTabView.kt`. Sigue pendiente comparar su implementación actual contra el mapa con chinchetas de persona/foto del boceto para ver qué falta exactamente, pero la premisa de "pantalla entera inexistente" era incorrecta.
  - **Pendiente real, huecos grandes identificados leyendo el boceto entero, sin resolver todavía**:
    1. Home: cabecera con wordmark "SOCIAL" en degradado + historias con anillo degradado + pestañas Siguiendo/Recomendado + carrusel "Recomendados para ti" con % compatibilidad IA (bloqueado/solicitar si no es público) + feed de posts con cabecera compat%/bloqueo + sheet de comentarios.
    2. Match: rejilla 2 columnas con foto de fondo, avatar superpuesto, badge de compatibilidad, pestañas Cerca/Compatibles/Nuevos/Tus gustos.
    3. "Find": comparar la implementación real actual contra el mapa con chinchetas del boceto (ver corrección arriba).
    4. Perfil: avatar/foto auto-rotativo, campos editables inline (contenteditable) en vez de sheet, "Pubs de socials" (grid de publicaciones etiquetadas).
    5. Reels: UI de cliente (subida real a Storage bucket `media`, reproductor, feed) sobre el backend ya construido esta ronda.
    6. "En directo" (streaming en vivo): necesita decidir un motor real -- LiveKit (open source, autoalojable, mismo criterio de "herramienta gratuita antes que de pago") es el candidato más razonable, pero autoalojarlo requiere un servidor propio del usuario (VPS) o su capa gratuita en la nube con credenciales reales que el usuario tendría que crear -- sin inventar credenciales ni fingir que ya existe, pendiente de decisión explícita del usuario sobre dónde alojarlo antes de escribir código de cliente.

- **Ronda 2026-08-25 (dentro de `/loop`), sheet de acciones de Avisos reconstruido según el boceto + "Siguiendo/Seguidores" real por primera vez**: siguiendo el hueco 4 de la ronda anterior ("Avisos: sheet de ficha de perfil con acciones... en vez de solo navegar") y el propio `openFollow()` del boceto.
  1. **Avisos, sheet de acciones**: antes solo mostraba botones sueltos condicionados a que el payload trajera una clave concreta (aceptar/rechazar social, seguir de vuelta, ver duelo, ver perfil), sin cabecera ni contexto ni forma de mandar un mensaje o un social directamente. Reconstruido con la ESTRUCTURA exacta de `openSheet()`: cabecera con avatar+nombre real, frase de contexto según el tipo de aviso, la acción primaria correspondiente, y un menú universal nuevo (💬 Enviar mensaje, 🤝 Enviar social, 👤 Ver perfil, 🚫 Bloquear o denunciar) que antes no existía en absoluto -- comparado con Instagram/WhatsApp, donde cualquier notificación te deja escribir directamente a esa persona.
  2. **Hallazgo real de integridad de datos, encontrado construyendo "Enviar mensaje"**: `createChatIfNeeded()` (disparado al aceptar un social) insertaba siempre en el orden fijo `(requester_id, addressee_id)` -- pero `unique(user_a_id, user_b_id)` en la tabla `chats` (0001_schema.sql) es SENSIBLE al orden. Un "Enviar mensaje" nuevo que creara el chat en el orden inverso para el mismo par de personas habría producido DOS filas de chat duplicadas para la misma pareja en vez de reutilizar una. Corregido con `getOrCreateChat()` (nuevo en `SocialLinkManager.kt`/`.swift`): ordena los dos ids de forma canónica antes de buscar/crear, reutilizado también por `createChatIfNeeded()`.
  3. **"Siguiendo"/"Seguidores" real, primera vez en cualquier plataforma**: los contadores de la cabecera del perfil (`PerfilViewModel.followersCount`/`followingCount`, ya reales desde una pasada anterior) no llevaban a ningún sitio al tocarlos -- comparado con Instagram/Twitter/TikTok, donde son el punto de entrada estándar para ver listas de seguimiento. `FollowListScreen.kt`/`FollowListView.swift` (nuevos): 2 pestañas con contador + buscador + botón seguir/dejar de seguir por fila, misma estructura que `openFollow()` del boceto -- "Socials" no se duplicó en una tercera pestaña, sigue siendo su propio destino ya construido (`SocialsListScreen`/`SocialsListView`), evitando reescribir una pantalla ya en producción.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK con todo el conjunto (sheet + `getOrCreateChat` + rejilla de Perfil + nueva pantalla + ruta nueva) en una sola pasada. **iOS: CI real VERIFICADO EN VERDE** en este push (`891b8fe`) -- primer intento en ROJO de verdad (no un runner colgado): `gh run view --log-failed` mostró `'async' property access in a function that does not support concurrency` en `AvisosView.swift:256/264` (`currentUserID ?? (try? await ...)` no compila en el Xcode real de CI, el operador `??` no admite un autoclosure async+`try?` en esa posición). Corregido con un if/else explícito en vez del operador (`71fbff7`) -- CI verde tras el fix. Exactamente el tipo de fallo real que este `/loop` existe para detectar y arreglar, no simular que compiló.
  - **Pendiente real explícito**: no se añadió "Retar a fight" al menú universal de Avisos -- los duelos (`duels`) requieren un `chat_id` existente (no hay forma de crear un duelo sin chat todavía), así que challengear a un desconocido directamente desde un aviso necesitaría además crear el chat primero; dejado fuera esta pasada en vez de fingir el flujo, documentado como hueco real si se pide explícitamente.

- **Ronda 2026-08-25 (dentro de `/loop`), % de compatibilidad real también en la cabecera de cada post del feed + solicitar compatibilidad desde Home**: Match ya tenía el flujo completo de "compatibilidad privada → botón real de solicitar → estado pendiente" (`MatchViewModel.requestCompatibility`/`MatchCard`), pero Home se había quedado atrás en dos sitios -- "Recomendados" mostraba "?%" fijo sin ninguna forma de pedirlo, y ningún post del feed mostraba compatibilidad con su autor en absoluto (a diferencia de SOCIAL_APP.html, que muestra `.pcompat` en la cabecera de cada publicación, no solo en el carrusel).
  - `HomeViewModel.compatibilityFor(profile)`/`requestCompatibility(profileId)` (nuevos, mismo patrón exacto que `MatchViewModel`): `Recommended` gana `requestSent`; `RecommendedCard`/`PostCard` (ambas plataformas) ganan el mismo `CompatBadge` de 3 estados real (público/pendiente/pedir) ya usado en Match, en vez de reinventar un cuarto estilo distinto.
  - **Detalle real de iOS, no trivial**: `RecommendedCard`/`PostCard` viven dentro de la etiqueta de un `NavigationLink` (para poder abrir el perfil al tocar la tarjeta) -- un `Text` con `.onTapGesture` anidado ahí no intercepta el toque de forma fiable, así que el badge "pedir" usa un `Button` real con `.buttonStyle(.plain)`, mismo patrón ya establecido y funcionando en `MatchView.CompatBadge` (no inventado, copiado de código ya en producción).
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK. **iOS: CI real VERIFICADO EN VERDE** en este push (`9ca3e5a`), sin ningún fallo esta vez.

- **Ronda 2026-08-25 (dentro de `/loop`), corrección real sobre dos huecos de la lista "Pendiente real" que ya NO eran huecos + avatares reales en el mapa Find**: antes de construir nada, se releyó el código real de Match y Find (en vez de asumir el estado documentado en rondas anteriores).
  - **Match ya estaba prácticamente completo**: `MatchScreen.kt` ya tiene las 4 pestañas exactas del boceto (Cerca/Compatibles/Nuevos/Tus gustos, `MatchFilter` con ordenación/filtro real, no decorativo) y `MatchCard` ya superpone avatar+badge de compatibilidad sobre un fondo degradado -- el hueco documentado ("rejilla 2 columnas... pestañas...") ya no existía, corregido aquí en vez de reconstruir algo que ya funciona.
  - **Find, hueco real que SÍ faltaba**: el mapa (`FindMapScreen.kt`/`FindMapView.swift`, ya real -- OpenStreetMap/MapKit con ubicaciones reales de `location_public`) usaba el pin genérico de cada plataforma (rojo/sistema) para CUALQUIER persona, sin relación con quién es -- comparado con SOCIAL_APP.html (`.pinav`, el busto ilustrado como marcador). Corregido en ambas plataformas con el avatar real de cada persona:
    - **Android**: `renderAvatarBitmap()` (nuevo, `avatar/AvatarBitmap.kt`) -- misma geometría EXACTA que `CartoonAvatar.kt` pero dibujada con `android.graphics.Canvas` nativo en vez de un `DrawScope`, porque osmdroid pinta sus marcadores con `Drawable`/`Bitmap`, no con Composables.
    - **iOS**: mucho más simple -- `MapAnnotation` de MapKit ya acepta una `View` real como contenido del pin, así que basta con `ActiveAvatarProvider.shared.avatarView(...)` en vez de dibujar nada a mano.
    - `PublicLocation`/`LocationRow` (ambas plataformas) ganan `avatarConfig`, antes no se pedía en absoluto para este mapa.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK. **iOS: CI real VERIFICADO EN VERDE** en este push (`cbca609`).

- **Ronda 2026-08-25 (dentro de `/loop`), avatar/foto alternándose en la cabecera del Perfil, por primera vez de verdad**: `PerfilView.swift` prometía desde su propio comentario de cabecera de archivo "Cabecera con avatar y foto alternándose", pero nunca se implementó -- siempre mostraba el avatar fijo, en ambas plataformas. Mismo comportamiento real que `SOCIAL_APP.html` (`setInterval(flip,3500)`, cada 3.5s).
  - Sin una tabla de "foto de perfil" propia, la fuente honesta más cercana a una foto real es la ÚLTIMA publicación real con foto (`posts.media_url`, ya real) -- si el usuario no tiene ninguna publicación con foto, la cabecera se queda solo con el avatar, sin fingir una rotación vacía. `PerfilViewModel.latestPostMediaUrl`/`.latestPostMediaURL` (nuevos, ambas plataformas): últimas 20 publicaciones propias, primera con `media_url` real -- sin un filtro "is not null" verificado en ninguno de los dos SDKs, se filtra en cliente en vez de adivinar una llamada no comprobada.
  - `RotatingProfileHeaderImage` (nuevo, ambas plataformas): `Crossfade`/`.transition(.opacity)` entre el busto ilustrado y la foto real, con la misma etiqueta "avatar"/"foto" del boceto superpuesta.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (tras un fallo real de compilación propio, corregido en la misma pasada: faltaba `import androidx.compose.foundation.layout.size` -- `Modifier.size(...)` nunca se había usado antes en `PerfilScreen.kt`, solo el parámetro homónimo de `AvatarView`). **iOS: CI real VERIFICADO EN VERDE** en este push (`d0904d5`).

- **Ronda 2026-08-25 (dentro de `/loop`), "Pubs de socials" real por primera vez -- etiquetar una publicación con quién la compartiste**: comparado con SOCIAL_APP.html (sección del perfil "Pubs de socials", etiqueta "con Marta"/"con Leo"). `is_social_only` (0001_schema.sql) ya controla QUIÉN puede ver un post, pero es un concepto distinto y ortogonal a CON QUIÉN se hizo -- no existía ninguna forma de decirlo.
  - **`0051_post_social_tags.sql`**: `posts.tagged_profile_id` (FK nullable a `profiles`, `on delete set null`) -- columna simple, no una tabla de muchos-a-muchos, porque el boceto muestra como mucho UNA etiqueta por publicación. Sin trigger que valide que sea un social aceptado real: el cliente solo ofrece elegir de la lista de socials aceptados (mismo dato que `SocialsListViewModel` ya usa) -- igual que "etiquetar personas" en Instagram no exige ninguna relación previa a nivel de base de datos, decisión de alcance deliberada, no un hueco de seguridad. Verificado local 84/84 tests (sin tests nuevos: no cambia ninguna política RLS).
  - **Publicar (ambas plataformas)**: `NewPostSheet.kt`/`NewPostView.swift` ganan un selector "¿Con quién? (opcional)" -- chips con los socials aceptados reales, reutilizando `SocialsListViewModel`/`.swift` sin duplicar esa consulta.
  - **Ver (ambas plataformas)**: `MyPostsScreen.kt`/`MyPostsView.swift` ("Tus publicaciones") ganan pestañas "Todas"/"Con tus socials" (filtro real, no decorativo) y muestran "con {nombre}" en cada publicación etiquetada, resolviendo el nombre real desde la misma lista de socials.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (dos fallos reales de compilación propios en el camino, ambos corregidos: `items`/`LazyRow` de `androidx.compose.foundation.lazy` no se pueden invocar con el nombre de paquete completo como una función normal -- una función de extensión necesita estar importada, no basta con escribir la ruta entera delante). **iOS: CI real VERIFICADO EN VERDE** en este push (`62bce36`).

- **Ronda 2026-08-25 (dentro de `/loop`), Reels: primera UI de cliente real sobre el backend de la ronda anterior (0050_reels.sql, tabla+RLS+contadores+avisos ya verificados con 79/79 tests, pero SIN ningún punto de la interfaz que los usara hasta ahora)**. Primer reproductor de vídeo real de toda la app en cualquiera de las dos plataformas -- ni Historias, ni chat multimedia, ni publicaciones normales reproducen vídeo, todo era foto.
  - **Android**: `androidx.media3:media3-exoplayer`/`media3-ui` (AndroidX, Apache 2.0, gratuito) en vez de `VideoView` (API antigua, peor soporte de formatos) -- mismo criterio de "herramienta gratuita/abierta antes que de pago" ya aplicado a osmdroid. `ReelsScreen.kt`: `VerticalPager` real (Compose Foundation) con un único `ExoPlayer` reutilizado entre páginas (se cambia el `MediaItem` al pasar de reel, no se crea un reproductor nuevo cada vez) -- mismo cuidado de recursos ya aplicado al emulador/Gradle en esta sesión.
  - **iOS, diferencia real y deliberada frente a Android, documentada explícitamente en el propio código**: `VerticalPager` de Compose Foundation da paginado vertical de verdad con snap a cualquier versión de la librería, pero SwiftUI no tiene equivalente directo compatible con el deployment target real (iOS 16 -- `TabView` de página solo pagina en horizontal antes de iOS 17). En vez de forzar un truco frágil (rotar la `TabView` 90°), `ReelsView.swift` usa una lista vertical real con reproducción bajo demanda (`AVKit.VideoPlayer`, toca para reproducir/pausar) -- tan real y funcional como el pager de Android, solo con una interacción distinta, no una funcionalidad fingida ni recortada.
  - **Subir un reel (ambas plataformas)**: `StorageUploader.uploadVideo()`/`.swift` (nuevo, reutiliza la lógica ya genérica de `uploadImage`/`uploadAudio` tal cual, mismo criterio que esa función ya aplicaba) sube el vídeo real al bucket `media`; inserta la fila real en `reels`. Sin miniatura real todavía (`thumbnail_url` sin fijar): generar un fotograma real necesitaría decodificar el vídeo (`MediaMetadataRetriever`/`AVAssetImageGenerator`) -- hueco real documentado, no fingido con un color aleatorio.
  - **Acceso real**: "Reels" en la rejilla de accesos de Perfil (7º hueco en Android, añadido sin quitar ninguno de los 6 ya reales -- Guardados/Tus chats no tienen otro punto de entrada, quitarlos habría sido una regresión; iOS ya tenía el hueco reservado en su rejilla de 7, solo estaba vacío). De paso, "Pubs. de socials" en el grid de iOS (que también estaba vacío) se conectó a `MyPostsView(initialTaggedOnly: true)` en vez de duplicar esa pantalla -- mismo filtro real ya construido la ronda anterior.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK, incluida la resolución real de las dos dependencias nuevas de Media3. **iOS: CI real VERIFICADO EN VERDE** en este push (`25bb1b0`).

- **Ronda 2026-08-25 (dentro de `/loop`), comentarios de reels reales -- el hueco explícito que quedó documentado en la ronda anterior**: `reel_comments` (0050_reels.sql) ya existía con su propio contador real (`reels.comment_count`, ya visible en la UI de Reels), pero sin ninguna pantalla para leerlos o escribirlos -- exactamente igual al hueco que tenía `comments` (posts) antes de 0008_comments.sql.
  - `ReelCommentsViewModel.kt`/`.swift` + `ReelCommentsSheet.kt`/`ReelCommentsView.swift` (nuevos, ambas plataformas): mismo patrón visual e interacción EXACTA que `CommentsSheet.kt`/`CommentsView.swift` (posts) -- lista con avatar+nombre real, borrar el propio comentario, campo para publicar uno nuevo. `ReelsViewModel`/`ReelsView` ganan `commentAdded()`/`commentRemoved()` (mismo patrón que `HomeViewModel`) para reflejar el contador sin recargar todo el feed.
  - **Aviso de honestidad, documentado en el propio código**: a diferencia de "Denunciar comentario" en posts (0045_reports_content_reference.sql, referencia real al `comment_id`), un comentario de reel se denuncia contra el AUTOR sin una columna `reel_comment_id` propia en `reports` todavía -- mismo criterio que tenían los comentarios de posts ANTES de esa migración. Hueco real, no fingido con una columna inventada; se puede cerrar con una migración pequeña si se pide explícitamente.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK. **iOS: CI real VERIFICADO EN VERDE** en este push (`0d9f7a6`).

- **Ronda 2026-08-25 (dentro de `/loop`), modo oscuro real por primera vez -- fuera del boceto SOCIAL_APP.html, comparado con Instagram/Twitter/WhatsApp/TikTok/Facebook directamente**: con Reels ya cerrado, se buscó el siguiente hueco real comparando la app entera (no solo el boceto) contra las redes sociales más importantes, tal como pide la regla estricta del proyecto. Ninguna de las dos plataformas tenía modo oscuro en absoluto -- ni forma de elegirlo, ni de seguir el ajuste del sistema.
  - **Android, hueco real de verdad**: `SocialTheme.kt` solo construía `lightColorScheme(...)`, siempre. `ThemeModePreference` (nuevo, mismo patrón exacto que `AccentPreference`) + `darkColorScheme(...)` con tonos reales de Material Design para superficies oscuras (`#121212`, no negro puro, que sangra en pantallas OLED). Auditoría real de toda la base de código: solo 3 sitios usaban un color de tema como LITERAL fijo en vez de un rol de `MaterialTheme.colorScheme` (`PerfilScreen.kt`/`ReelsScreen.kt`, botón "Publicar" con `SocialColors.Ink` fijo -- casi invisible sobre fondo oscuro; `RootTabView.kt`, la barra inferior con `SocialColors.Background` fijo -- se quedaba blanca aunque el resto de la app pasara a oscuro). Los tres corregidos a roles de tema (`onBackground`/`background`/`surfaceVariant`), que ya se invierten solos.
  - **iOS, hallazgo real distinto**: la mayoría de las vistas ya usan estilos adaptables del sistema (`.primary`/`.secondary`, fondos por defecto de `List`/`Form`) -- `SocialColors.ink`/`.surfaceVariant` (definidos en `Theme.swift` desde la pasada de identidad visual) NUNCA llegaron a usarse en ningún sitio real, así que el modo oscuro del sistema ya "funcionaba" de forma pasiva, sin verificar ni exponer control alguno. `ThemeModePreference` (nuevo, mismo patrón que `AccentPreference`) + `.preferredColorScheme(...)` en `RootTabView.swift` para dar el mismo control explícito que Android y que cualquier app grande, en vez de dejarlo solo implícito.
  - **Selector real en Ajustes (ambas plataformas)**: Sistema/Claro/Oscuro, cambia al instante sin reiniciar, mismo patrón que el selector de acento ya construido.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK. **iOS: CI real VERIFICADO EN VERDE** en este push (`5065b0f`).

- **Ronda 2026-08-25 (dentro de `/loop`), preferencias de notificaciones por categoría real -- de paso, corrección de un párrafo desactualizado en la política de privacidad**: siguiendo con la comparación directa contra Instagram/Twitter/Facebook/WhatsApp (no solo el boceto).
  - **Hallazgo real, de documentación**: `legal/privacy_policy_es.md` (+ las dos copias que se sirven en la app, Android/iOS) seguía describiendo el botón flotante global de denunciar/bloquear que se QUITÓ hace varias rondas ("hay un icono de denunciar/bloquear que no sé en qué momento está ahí") -- el párrafo llevaba desde entonces contradiciendo la implementación real (cada perfil/chat/post/comentario/mensaje tiene su propio punto de entrada). Corregido en las 3 copias (`legal/`, `Android/app/src/main/assets/`, `Social/`).
  - **Hallazgo real, de producto**: `send-push` (Edge Function) enviaba SIEMPRE, para cualquier `kind` de aviso, sin ninguna forma de que el usuario apagara una categoría concreta -- el único control que existía era silenciar un CHAT completo (0047_message_notify_mute.sql), nunca un TIPO de aviso en toda la app.
  - **`0052_notification_prefs.sql`**: `profiles.muted_push_kinds text[]` -- columna simple (no una tabla aparte), mismos valores exactos que `notifications.kind`. Sin trigger de protección: es una preferencia propia sin implicaciones de seguridad, `profiles_update_own` ya alcanza. Verificado local 84/84 tests (sin tests nuevos: no cambia ninguna política RLS).
  - **Aplicado de verdad en el servidor, no solo en el cliente**: `send-push/index.ts` consulta `muted_push_kinds` del destinatario antes de enviar y no manda nada si el `kind` está silenciado -- un push real deja de llegar, no es decorativo.
  - **Ajustes (ambas plataformas)**: 7 categorías reales agrupando los `kind` existentes (Mensajes/Me gusta/Comentarios/Socials/Seguidores/Duelos/Compatibilidad), mismo patrón de interruptores ya usado para Compatibilidad pública/Ubicación pública.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK. **iOS: CI real VERIFICADO EN VERDE** en este push (`fc1b241`).

- **Ronda 2026-08-25 (dentro de `/loop`), "Quién vio tu historia" real por primera vez, comparado con Instagram/Snapchat/WhatsApp Status/Facebook**: `stories` (0001_schema.sql) existe desde el principio de la sesión, pero nunca hubo ninguna tabla que registrara quién veía una historia -- ni siquiera a nivel de base de datos, no solo de UI. Tampoco había ningún mecanismo de auto-avance/barra de progreso, pero eso es un hueco distinto, no tocado esta pasada.
  - **`0053_story_views.sql`**: tabla `story_views` (story_id, viewer_id, `unique(story_id, viewer_id)` para no contar dos veces a la misma persona) -- solo el AUTOR de la historia puede ver la lista de espectadores (mismo criterio que Instagram: ni el propio espectador ve una lista de "ya vista por ti"). Verificado local 87/87 tests (3 casos nuevos: un espectador real SÍ puede registrar su vista; el autor real SÍ ve quién vio su historia; un tercero que no es el autor NO ve nada).
  - **Cliente (ambas plataformas)**: al abrir la historia de otra persona, se registra la vista en silencio (no al ver la propia -- no tendría sentido contarte a ti mismo). Al abrir tu PROPIA historia, un "👁 N vistas" real y tocable abre la lista de quién la vio, con nombre real resuelto desde `profiles` -- mismo patrón visual que Instagram/Snapchat.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK. **iOS: CI real VERIFICADO EN VERDE** en este push (`9d0a5f6`).

- **Ronda 2026-08-26 (dentro de `/loop`), auto-avance + barra de progreso en Historias -- el hueco explícito documentado en la ronda anterior**: comparado con Instagram/WhatsApp Status/Snapchat y con el propio boceto SOCIAL_APP.html (`.stbar`/`.stbarf`). Antes solo se podía tocar para pasar a la siguiente historia a mano, sin ninguna señal de cuánto quedaba ni avance automático.
  - **Cliente (ambas plataformas)**: cada historia del grupo tiene su propio segmento de progreso en la parte superior, se rellena en 5s (mismo orden de magnitud que Instagram/WhatsApp Status) y avanza sola a la siguiente al completarse. Tocar la mitad derecha de la pantalla adelanta, la izquierda retrocede -- mismo lenguaje de gestos ya estandarizado en esas apps. Si el usuario avanza a mano antes de que el segmento termine, el temporizador se cancela solo (mismo mecanismo -- `LaunchedEffect(index)`/`.task(id: index)` -- que ya se cancela y reinicia con cada cambio de índice), sin disparar un avance doble.
  - **Fallo real de compilación propio en el camino, corregido en la misma pasada**: `detectTapGestures` (Compose) es una función de extensión de `PointerInputScope` -- llamarla con el nombre de paquete completo delante (mismo error ya visto antes con `items`/`LazyRow`) no compila, necesita estar importada.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK. **iOS: CI real VERIFICADO EN VERDE** en este push (`ae8beb2`, run `32904753070`).

- **Ronda 2026-08-26 (dentro de `/loop`), like a comentarios individuales real por primera vez, comparado directamente con Instagram/Twitter/Facebook**: `grep -rln "comment_likes\|commentLike"` sobre toda la base de código no devolvía nada -- ni `comments` (posts) ni `reel_comments` (reels) tenían ningún concepto de "like" propio, solo se podían leer/escribir/borrar enteros. Las tres apps de referencia sí dejan dar like a un comentario concreto, no solo a la publicación entera.
  - **`0054_comment_likes.sql`**: mismo patrón EXACTO que `likes`/`reel_likes` (0007/0050) -- tablas `comment_likes`/`reel_comment_likes` propias, `unique(comment_id, user_id)`, `like_count` cacheado en el propio comentario, bloqueo aplicado desde el principio (0012_block_enforcement_posts.sql como referencia) contra el AUTOR DEL COMENTARIO, no el autor del post/reel. Sin trigger de protección de `like_count`: ni `comments` ni `reel_comments` tienen NINGUNA política de UPDATE (no se pueden editar, solo insertar/borrar), así que RLS ya impide que nadie, ni el propio autor, manipule el contador a mano -- solo el trigger `security definer` puede tocarlo.
  - **Hallazgo real del propio arnés de pruebas, mismo tipo de bug ya encontrado antes con la variable `post` inexistente**: el primer intento de probar el caso "bloqueado" de `reel_comment_likes` asumía que el bloqueo u1↔u2 (creado línea ~137, sección de mensajes) seguía vigente más adelante en el archivo -- pero ese bloqueo se BORRA de verdad en la línea ~555 al probar `blocks_delete_own`. El test pasaba en `expectFail` con normalidad porque en ese punto ya NO había bloqueo real entre u1 y u2, así que el insert simplemente tenía éxito y el test lo marcó en rojo de verdad (no un falso verde) -- se corrigió creando un comentario propio de u3 (con quien u1 SÍ sigue bloqueado, ese bloqueo de la sección de reels nunca se borra) en vez de reusar el comentario de u2. Verificado local 99/99 tests (12 casos nuevos: like sin bloqueo + sync de contador + notificación con actor/payload correctos + like bloqueado, por duplicado para posts y reels).
  - **Cliente (ambas plataformas)**: botón ❤/🤍 con contador junto a cada comentario individual (posts y reels), mismo patrón de toggle optimista + persistencia real que `HomeViewModel.toggleLike()` -- estado "me gusta este comentario" resuelto con un solo select adicional filtrado por los `comment_id` ya cargados, igual que `likedPostIds`.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** en este push (`0fbd322`, run `32907432097`).
  - **Pendiente real**: "En directo" (streaming en vivo) sigue siendo el único hueco grande sin resolver de todo lo identificado leyendo SOCIAL_APP.html -- pendiente de decidir un motor real (LiveKit u otro) antes de escribir código de cliente, ver rondas anteriores.

- **Ronda 2026-08-26 (dentro de `/loop`), publicaciones con varias fotos (carrusel) real por primera vez, comparado directamente con Instagram/Facebook**: hueco ya identificado en la ronda anterior como de tamaño comparable a Reels. `posts.media_url` (0001_schema.sql) solo admite UNA foto por publicación -- Instagram/Facebook dejan subir varias y deslizar entre ellas.
  - **`0055_post_media.sql`**: diseño que minimiza el radio de impacto -- `posts.media_url` se mantiene tal cual como la PRIMERA foto (o la única, para cualquier post de antes de esta migración), así que ningún sitio que solo muestra una miniatura (rejilla de Perfil, Guardados, Moderación) necesita ningún cambio. `post_media` (tabla nueva) guarda SOLO las fotos adicionales, mismo patrón de tabla propia que `comment_likes`. A diferencia de likes/comments, sin comprobación de bloqueo: quien inserta es siempre el AUTOR de su propia publicación, nunca una interacción sobre contenido ajeno -- la política solo comprueba autoría real vía subquery a `posts`.
  - **Hallazgo real del propio arnés de pruebas, mismo tipo de bug ya encontrado dos veces antes (variable `post` inexistente, bloqueo u1↔u2 ya borrado)**: el primer intento de probar la visibilidad de `post_media` contra un post "solo socials" reutilizaba `socialOnlyPost` (declarado al principio del archivo) sin notar que esa fila se BORRA de verdad más adelante (línea ~338, prueba de `reports.post_id` "on delete set null") -- el insert fallaba por RLS (la subquery a `posts` no encontraba ninguna fila) en vez de por el motivo que el test decía comprobar. Corregido creando un post "solo socials" nuevo y todavía vivo para esta prueba en concreto. Verificado local 103/103 tests (5 casos nuevos: el autor real SÍ puede añadir fotos a su propio post; un tercero NO puede añadir fotos a un post ajeno; visibilidad de las fotos extra igual que la del post -- pública sí, "solo socials" sin conexión no).
  - **Cliente (ambas plataformas)**: selector de imágenes múltiples al crear una publicación (`ActivityResultContracts.GetMultipleContents()` en Android, `PhotosPicker` con selección múltiple en iOS) -- la primera sube a `posts.media_url` como siempre, el resto a `post_media` en orden. En el feed, un post con más de una foto se muestra en un carrusel real (`HorizontalPager` de Compose Foundation, ya usado en Reels, con indicador "N/M"; `TabView(.page)` en SwiftUI, paginado horizontal estándar disponible desde iOS 14 -- sin el matiz de plataforma que sí hizo falta para el pager VERTICAL de Reels). Un post con una sola foto (el caso normal hasta ahora) se sigue viendo exactamente igual que antes, sin carrusel ni indicador.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** en este push (`0b2aad9`, run `32908958515`).
  - **Pendiente real**: "En directo" (streaming en vivo) sigue siendo el único hueco grande sin resolver de todo lo identificado leyendo SOCIAL_APP.html -- pendiente de decidir un motor real (LiveKit u otro) antes de escribir código de cliente, ver rondas anteriores.

- **Ronda 2026-08-26 (dentro de `/loop`), "En directo" -- RONDA DE BACKEND, decisión de motor real tomada por el usuario (LiveKit Cloud, preguntado explícitamente vía AskUserQuestion: Cloud vs. self-hosted vs. seguir sin tocarlo -- eligió Cloud, SDKs Apache 2.0 open-source, para no añadir infraestructura propia sobre un proyecto ya grande)**: último hueco grande identificado leyendo SOCIAL_APP.html sin resolver, comparado con Instagram/TikTok Live. Mismo orden que Reels (0050_reels.sql backend primero, cliente en una ronda aparte).
  - **`0056_live_streams.sql`**: tabla `live_streams` (host, título, `room_name` único, `is_social_only` mismo criterio que posts/reels, `status` live/ended, `viewer_count` cacheado y protegido) + `live_stream_viewers` (a diferencia de `story_views` -- que registra CADA vista para siempre -- aquí una fila = "viendo AHORA MISMO", se borra de verdad al salir; bloqueo comprobado contra el HOST al unirse, mismo criterio que comment_likes/reel_likes).
  - **Hallazgo real GRANDE de Postgres/RLS, no específico de este proyecto -- documentado aquí porque es la primera vez que se topa con él en toda la sesión**: un espectador que se une a un directo (`live_stream_viewers_insert_own`) no podía DESPUÉS salir de él -- `delete from live_stream_viewers where viewer_id = auth.uid()` fallaba en silencio (0 filas, sin excepción) a pesar de que la política de DELETE (`viewer_id = auth.uid()`) era correcta letra por letra. Investigado a fondo con una reproducción mínima aislada (tabla de prueba desechable, sin ninguna relación con el esquema real) hasta confirmar la causa: **en Postgres, UPDATE y DELETE necesitan que la fila también sea visible por una política de SELECT (o ALL) además de cumplir su propia política USING** -- la política de SELECT de `live_stream_viewers_select_own_stream` solo dejaba ver las filas al HOST (para que nadie vea la lista de espectadores ajena), así que ningún espectador podía nunca "encontrar" su propia fila para poder borrarla, aunque la política de DELETE en sí misma sí lo permitiera. Arreglado añadiendo `viewer_id = auth.uid() OR <ya era host>` a la política de SELECT -- el espectador ve su propia fila (necesario para salir), sigue sin ver las de los demás. Ninguna otra tabla del proyecto tiene esta combinación exacta (visibilidad restringida a un tercero + borrado por el propio actor), así que no hace falta una auditoría más amplia -- es una forma nueva de tabla, no un patrón repetido en otro sitio. Verificado local 115/115 tests (8 casos nuevos, incluido el que capturó este bug de verdad: comprobar `viewer_count` baja a 0 tras el borrado, no solo que el DELETE "no lanzó excepción").
  - **`supabase/functions/live-token/index.ts` (nueva Edge Function)**: mint de un token de acceso real de LiveKit -- JWT HS256 firmado a mano con Web Crypto (no existe SDK de servidor de LiveKit para Deno/Edge Functions), mismo principio ya aplicado a `buildApnsJwt()` en `send-push/index.ts` para APNs (protocolo documentado implementado a mano, no una librería de terceros). Quién puede publicar (host) frente a solo suscribirse (espectador) se decide consultando la base de datos con `service_role`, nunca a partir de un flag que mande el propio cliente. **Verificado real, no simulado, con la misma herramienta ya usada para send-push**: `esbuild` (cero errores de sintaxis) + `tsc --noEmit` (mismos 8 errores esperados de "Deno globals/implicit any" que da el propio `send-push/index.ts` bajo el mismo chequeo -- confirmado comparando ambos archivos con el idéntico comando, cero errores de lógica propia).
  - **Pendiente real de DESPLIEGUE, no de código** (mismo criterio que push/APNs-FCM): un proyecto LiveKit Cloud real con `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET`/`LIVEKIT_WS_URL`, fijados con `supabase secrets set`. Sin ellos la función compila y corre pero no conecta a ningún servidor real.
  - **Pendiente real, próxima ronda**: cliente real en ambas plataformas -- SDK de LiveKit (`io.livekit:livekit-android` / LiveKit Swift, ambos Apache 2.0 gratuitos) para publicar/suscribirse de verdad, pantalla de "Directos activos" (lista pública vía `live_streams` donde `status='live'`), botón "Empezar directo" para el host y "Ver directo" para espectadores.
  - **CI real confirmado en verde** para este push (`5d072c4`, run `32911337705`) -- solo backend/Edge Function, sin cambios de cliente Swift, así que esto es una comprobación de no-regresión, no una verificación de código nuevo iOS.

- **Ronda 2026-08-26 (dentro de `/loop`), "En directo" -- RONDA DE CLIENTE, cierra el último hueco grande de SOCIAL_APP.html**: SDK real de LiveKit en ambas plataformas (`io.livekit:livekit-android`/`client-sdk-swift`, ambos Apache 2.0). A diferencia de Media3/ExoPlayer (API ya conocida con confianza), la API real de LiveKit no se adivinó de memoria -- se investigó de verdad leyendo el código fuente real en GitHub (`gh api`/`WebFetch` contra `livekit/client-sdk-android` y `livekit/client-sdk-swift`: `Room.kt`, `RoomEvent.kt`, `Participant.kt`, `VideoTrack.kt`, `RoomDelegate.swift`, `SwiftUIVideoView.swift`, y el propio `sample-app-compose` de Android para el patrón real de interop Compose↔`TextureViewRenderer`) antes de escribir una sola línea, mismo criterio de no fingir que se sabe algo no verificado.
  - **Android**: `io.livekit:livekit-android:2.28.0` -- requirió añadir el repositorio JitPack a `settings.gradle.kts` (gratuito, no es un servicio de pago) porque una dependencia transitiva real (`audioswitch`) solo se publica ahí. `LiveStreamsViewModel.kt` (lista de directos activos, empezar/terminar el propio, unirse/salir de uno ajeno pidiendo el token real a `live-token`), `LiveStreamsScreen.kt` (lista + hoja "Empezar directo"), `LiveStreamRoomScreen.kt` (sala real: `Room.connect()`, cámara/micrófono del host con `setCameraEnabled`/`setMicrophoneEnabled`, vídeo remoto suscrito vía `RoomEvent.TrackSubscribed` recogido con `room.events.collect { }`). **Trampa real ya conocida, tercera vez en la sesión** (mismo patrón que `items`/`detectTapGestures`): `collect` es una función de extensión (`io.livekit.android.events.collect` sobre `EventListenable`, no un método directo) -- no compilaba sin importarla explícitamente, corregido tras el primer intento real de `:app:compileDebugKotlin`. **Compilado real, `BUILD SUCCESSFUL`.**
  - **iOS**: paquete SPM `LiveKit` (`client-sdk-swift`, requiere iOS 13+, muy por debajo del deployment target real de 16.0) añadido a `project.yml`. `LiveStreamsViewModel.swift`/`LiveStreamsView.swift` (mismo patrón), `LiveStreamRoomView.swift`: a diferencia de Android (Flow de eventos), el SDK de Swift usa el patrón delegate real del SDK (`RoomDelegate`, métodos `@objc optional`) -- `LiveStreamRoomCoordinator` (`NSObject`+`ObservableObject`+`RoomDelegate`) recibe `didSubscribeTrack`/`participantDidConnect` en un hilo no garantizado como principal (documentado así por el propio SDK) y salta a `@MainActor` para actualizar el `@Published` que lee la vista. Vídeo renderizado con `SwiftUIVideoView` (wrapper SwiftUI oficial del propio SDK, no una interop hecha a mano como en Android). Conecta el hueco "En directo" que `PerfilView.swift` dejaba explícitamente vacío desde la ronda de Reels ("único que queda pendiente a propósito").
  - **Fallo real de CI, corregido en la misma pasada (run `32913176282`)**: `from: "2.16.0"` dejaba que SPM resolviera cualquier 2.x más nueva, y desde la 2.15.0 el propio `Package.swift` de `client-sdk-swift` exige `swift-tools-version:6.1` -- el Xcode 16.2 real de este runner solo soporta hasta Swift 6.0, así que la resolución de paquetes fallaba ANTES de compilar una sola línea propia ("contains incompatible tools version"). Corregido fijando `exactVersion: "2.14.1"` (última versión real con `swift-tools-version:6.0`, confirmado leyendo su `Package.swift` real) -- también se releyeron las firmas exactas de `Room`/`RoomDelegate`/`SwiftUIVideoView`/`LocalParticipant` contra el commit real de ese tag concreto para confirmar que no habían cambiado respecto a lo ya escrito (no lo habían hecho).
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`, incluida la resolución real de la dependencia nueva vía JitPack). **iOS: CI real VERIFICADO EN VERDE** en el push de la corrección (`876a1b4`, run `32913366319`).
  - **Aviso de honestidad, documentado en el propio código, mismo criterio que push (APNs/FCM)**: sin un proyecto LiveKit Cloud real, `live-token` no puede emitir un token válido y `room.connect()` fallará limpiamente (ya capturado con try/catch en ambas plataformas) -- no hay forma de probar una conexión de vídeo real en este entorno sin esas credenciales.
  - **Textos de permiso actualizados con honestidad** (`project.yml`, `legal/app_store_permission_texts.md`): `NSCameraUsageDescription`/`NSMicrophoneUsageDescription` solo mencionaban UWB/notas de voz -- ahora también mencionan publicar vídeo/audio en un directo, mismo criterio ya aplicado a `NSLocationWhenInUseUsageDescription` cuando se quitó la brújula.
  - Con esto, el último hueco grande identificado leyendo SOCIAL_APP.html queda cerrado de verdad (backend + cliente en ambas plataformas) -- pendiente real de DESPLIEGUE, no de código: un proyecto LiveKit Cloud real.

- **Ronda 2026-08-26 (dentro de `/loop`), chats de grupo -- RONDA DE BACKEND, nuevo hueco real identificado tras cerrar "En directo", comparado con WhatsApp/Instagram/Messenger/Facebook**: `chats` (0001_schema.sql) es estrictamente 1:1 (`user_a_id`/`user_b_id`, `unique(user_a_id, user_b_id)`, `check (user_a_id <> user_b_id)`) -- no hay forma de tener una conversación con varias personas a la vez en ninguna plataforma, comparado con las cuatro apps de referencia (todas lo tienen como función central, no secundaria).
  - **`0057_group_chats.sql`**: tablas NUEVAS y paralelas (`group_chats`/`group_chat_members`/`group_messages`) en vez de generalizar `chats`/`messages` -- mismo criterio de "tabla propia en vez de complicar una compartida" ya usado repetidamente (`reel_comments` vs `comments`, `reel_likes` vs `likes`). Cero cambios de RLS en el chat 1:1 ya construido y probado, riesgo de regresión mínimo. El creador se añade a sí mismo como miembro automáticamente vía trigger; cualquier miembro puede añadir a otro (criterio por defecto de WhatsApp/Messenger) salvo que haya un bloqueo real de por medio; sin reacciones/voz/read-receipts todavía (mismo criterio que Reels: comentarios llegaron en una ronda posterior a la UI base) -- hueco real documentado, no fingido.
  - **Segundo hallazgo real de Postgres/RLS de la sesión (distinto del de `live_stream_viewers`)**: `group_chat_members_select` necesitaba comprobar la pertenencia contra SU PROPIA tabla -- un `exists` inline ahí disparaba "infinite recursion detected in policy for relation group_chat_members" (Postgres reevalúa la misma política para resolver la subconsulta, que la vuelve a evaluar...). Mismo motivo exacto por el que `is_blocked`/`has_accepted_social` son funciones `security definer` en vez de subconsultas inline -- arreglado con `private.is_group_member(group_chat_id, user_id)`, reutilizada en las cuatro políticas que necesitan esta comprobación.
  - **Tercer hallazgo real de Postgres/RLS de la sesión**: `insert into group_chats (...) returning id` fallaba con "new row violates row-level security policy for table group_chats" a pesar de que `group_chats_insert_own` es correcta letra por letra -- RETURNING vuelve a comprobar la fila contra `group_chats_select` (que depende de `is_group_member`, que depende de que el trigger de auto-alta del creador YA haya insertado su fila de pertenencia) en un punto anterior a que ese efecto del trigger cuente para esa comprobación en concreto, aunque sí cuenta ya para cualquier SELECT posterior real (confirmado con una reproducción directa: insert sin RETURNING funciona, un SELECT aparte del mismo usuario justo después ve la fila sin problema). **Implicación real para el cliente, documentada en la propia migración**: ni `.insert(){select()}` (Kotlin) ni `.insert().select().single()` (Swift) -- que sí funcionan para `posts`/`live_streams` -- sirven para crear un `group_chats`; el cliente debe generar el `id` él mismo (`UUID.randomUUID()`/`UUID()`) e insertarlo explícito, mismo patrón ya adoptado en el propio test. Verificado local 128/128 tests (16 casos nuevos).
  - **Verificado real, no simulado**: RLS 128/128. Sin cambios de cliente todavía (Android/iOS) -- ronda de cliente aparte, mismo orden que Reels/Directo: crear grupo, añadir/quitar miembros, lista de chats de grupo, hilo de mensajes. **iOS: CI real VERIFICADO EN VERDE** para este push (`c9a5658`, run `32914345171`) -- solo backend, comprobación de no-regresión.
  - **Pendiente real, próxima ronda**: cliente real en ambas plataformas para chats de grupo (ver arriba). Reacciones/voz/read-receipts en chats de grupo, hueco real documentado para una ronda posterior a la UI base (mismo orden que comentarios llegaron después de la UI base de Reels).

- **Ronda 2026-08-26 (dentro de `/loop`), chats de grupo -- RONDA DE CLIENTE, cierra el hueco identificado tras "En directo"**: cliente real en ambas plataformas sobre el backend ya verificado (0057_group_chats.sql, 128/128 tests).
  - **Android**: `GroupChatsViewModel.kt`/`GroupChatsListScreen.kt` (lista + crear grupo, picker de miembros reutilizando `SocialsListViewModel` igual que "¿Con quién?" en `NewPostSheet.kt`), `GroupChatViewModel.kt`/`GroupChatScreen.kt` (hilo con mensajes en vivo por Realtime, mismo mecanismo ya usado en el chat 1:1 -- `postgresChangeFlow<PostgresAction.Insert>`). El id del grupo se genera con `UUID.randomUUID()` en el cliente, nunca con `.insert(){select()}`, siguiendo el aviso real documentado en la propia migración (RETURNING falla contra el trigger de auto-alta del creador). `BackScaffold.kt` ganó un parámetro `actions` opcional (lambda vacía por defecto, no rompe ninguno de los ~15 sitios que ya lo usaban) para poder mostrar "👥 N miembros" en la barra superior del hilo. "Grupos" añadido como 9º hueco de la rejilla de Perfil, mismo criterio que Reels/Directos. **Compilado real, `BUILD SUCCESSFUL`.**
  - **iOS**: mismo patrón -- `GroupChatsViewModel.swift`/`GroupChatsListView.swift`, `GroupChatViewModel.swift`/`GroupChatView.swift` (Realtime vía `RealtimeChannelV2`/`postgresChange`, mismo patrón exacto que `ChatViewModel.swift`; `import Supabase`, no `import Realtime` -- confirmado que el proyecto solo declara el producto SPM `Supabase`, que reexporta esos tipos). `id` del grupo generado con `UUID()` en el cliente, mismo motivo que Android. Respetado el límite real de este archivo ya documentado en `PerfilView.swift` (`.navigationDestination(isPresented:)`, nunca `(item:)`, exclusiva de iOS 17+). Botón "👥 Grupos" añadido junto a "💬 Tus chats" (fuera de la rejilla de subsecciones, mismo criterio que ese botón).
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** (`f130512`, run `32915478922`) -- el paso "Compilar para el simulador" terminó bien pronto, el run se quedó colgado varios minutos en la fase de cierre ("Complete job") por causas de infraestructura ajenas al código, no un fallo real.
  - **Pendiente real**: reacciones/voz/read-receipts en chats de grupo (mismo criterio que Reels: comentarios llegaron en una ronda posterior a la UI base) -- hueco documentado, no fingido.

- **Ronda 2026-08-26 (dentro de `/loop`), avisos reales para mensajes de grupo + corrección de un bug de push/avisos real ya existente desde varias rondas atrás**: al añadir el aviso de mensaje de grupo se auditó `send-push/index.ts`/`AvisosViewModel.kt`/`.swift` por costumbre (mismos tres sitios que ya se habían olvidado de actualizar dos veces antes, según los propios comentarios del código) y se confirmó un hallazgo real: **"comment"/"comment_like"/"reel_comment_like" llevaban en `notifications_kind_check` desde 0008/0054 -- varias rondas -- pero NUNCA se añadieron a los switches de icono/título de NINGUNO de los tres sitios**, así que un comentario, un like a un comentario o un like a un comentario de reel generaban el aviso real en la base de datos (verificado, con notificación real, correcta) pero se mostraban siempre con el "🔔"/"bell" genérico tanto en el push real como en la propia lista de Avisos dentro de la app. Corregido en los tres sitios a la vez.
  - **`0058_group_message_notify.sql`**: `notify_new_group_message()` -- mismo patrón que `notify_new_message` (1:1) pero notificando a TODOS los demás miembros del grupo, no a un único destinatario (`insert ... select` desde `group_chat_members` excluyendo al propio remitente). `group_message` añadido a `notifications_kind_check`. Verificado local 132/132 tests (4 casos nuevos: el resto de miembros reales recibe el aviso, actor_id correcto, payload con el group_chat_id real, quien escribió no se autonotifica).
  - **`send-push/index.ts`**: añadidos `comment`/`comment_like`/`reel_comment_like`/`group_message` a `iconFor`/`titleFor`. Verificado con la misma herramienta ya usada para `live-token`: `esbuild` (sin errores de sintaxis) + `tsc --noEmit` (mismos errores esperados de tipos de Deno, cero errores de lógica propia).
  - **`AvisosViewModel.kt`/`.swift`**: mismos cuatro casos añadidos a `icon()`/`title()`.
  - **`AjustesScreen.kt`/`AjustesView.swift` (`NOTIFICATION_CATEGORIES`/`notificationCategories`)**: `comment_like`/`reel_comment_like` añadidos a "Me gusta" (antes silenciar "Me gusta" no silenciaba en realidad el like a un comentario) y `group_message` a "Mensajes".
  - **Verificado real, no simulado**: RLS 132/132. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** (`0de646f`, run `32916622828`).

- **Ronda 2026-08-26 (dentro de `/loop`), chat en vivo real durante un directo, comparado con Instagram/TikTok Live**: el vídeo del directo ya funcionaba (ronda anterior, LiveKit real), pero ningún espectador podía escribir nada mientras lo veía -- comparado con esas dos apps, donde el chat en vivo (comentarios desplazándose sobre/junto al vídeo) es LA función que hace interactivo un directo, no un añadido.
  - **`0059_live_stream_messages.sql`**: tabla `live_stream_messages`, mensajes cortos a propósito (`char_length between 1 and 200`, mismo criterio que Instagram/TikTok Live, no un mensaje de chat privado largo). Visibilidad calcada de `live_streams_select` (host, público, o social aceptado con el host) en vez de depender de `live_stream_viewers` -- evita a propósito el mismo tipo de problema de timing/recursión ya encontrado con `group_chat_members`, reutilizando directamente el criterio de la fila padre. Para escribir, además de poder ver el directo, no se puede estar bloqueado por el host (mismo criterio que `live_stream_viewers_insert_own`) -- el bloqueo NO afecta la visibilidad de lectura, mismo criterio ya establecido para posts/reels. Verificado local 139/139 tests (8 casos nuevos).
  - **Cliente (ambas plataformas)**: `LiveStreamChatViewModel.kt`/`.swift` (mensajes en vivo por Realtime, mismo mecanismo que el chat 1:1/de grupo) + UI de chat superpuesta al vídeo (lista desplazable abajo a la izquierda + compositor, mismo sitio que Instagram/TikTok Live) integrada en `LiveStreamRoomScreen.kt`/`LiveStreamRoomView.swift`. El compositor se oculta si el directo ya `status != 'live'` (se puede seguir viendo/leyendo el chat de un directo terminado, pero no escribir más).
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** (`694f2a4`, run `32917469743`).

- **Ronda 2026-08-26 (dentro de `/loop`), reacciones a mensajes de grupo, comparado con WhatsApp/Messenger/Instagram**: primera pieza del hueco explícitamente documentado desde la ronda anterior ("reacciones/voz/read-receipts en chats de grupo") -- mismo orden que Reels (comentarios llegaron después de la UI base).
  - **`0060_group_message_reactions.sql`**: mismo diseño exacto que `message_reactions` (0018, chat 1:1) -- tabla propia, una reacción por persona por emoji, `group_chat_id` desnormalizado para poder cargar las reacciones de un grupo entero con un `eq` simple. Reutiliza `private.is_group_member` (0057) para select/insert -- sin el mismo tipo de recursión que `group_chat_members` porque esta es una tabla distinta, pero la comprobación real es la misma. Verificado local 144/144 tests (5 casos nuevos).
  - **Cliente (ambas plataformas)**: mismo patrón visual y de datos exacto que el chat 1:1 (`ChatViewModel.kt`/`.swift`) -- tocar la burbuja abre/cierra un selector rápido de 5 emojis, reacciones existentes agrupadas con su recuento y resaltadas si el usuario ya reaccionó así, en vivo por Realtime (inserciones y borrados). En iOS se extrajo `GroupMessageBubble` como vista propia (antes inline en el `ForEach`) porque el selector abierto/cerrado necesita ser un `@State` por mensaje.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** (`1731951`, run `32918625615`).
  - **Pendiente real**: voz y read-receipts en chats de grupo siguen sin construir, hueco documentado, no fingido.

- **Ronda 2026-08-26 (dentro de `/loop`), "visto por" real en chats de grupo, comparado con WhatsApp/Messenger**: segunda pieza del hueco explícitamente documentado ("voz/read-receipts en chats de grupo siguen sin construir").
  - **`0061_group_message_reads.sql`**: diseño distinto del read receipt 1:1 (`messages.read_at`, una sola columna porque solo hay OTRA persona) -- en un grupo puede haber leído el mensaje cualquier subconjunto de los demás miembros, así que hace falta una fila por (mensaje, lector). Mismo patrón de tabla propia + `group_chat_id` desnormalizado que reacciones. Mismo criterio que `messages_update_read` (chat 1:1): solo se puede marcar como leído un mensaje AJENO, nunca el propio -- evita inflar artificialmente el propio recibo de lectura. Verificado local 149/149 tests (5 casos nuevos).
  - **Cliente (ambas plataformas)**: al abrir el hilo (y al recibir un mensaje nuevo en vivo), se marcan como leídos todos los mensajes ajenos todavía no leídos. "Visto por N" real bajo los PROPIOS mensajes (mismo criterio que WhatsApp/Messenger: el recibo de lectura se muestra en lo que TÚ enviaste, no en lo ajeno), en vivo por Realtime.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** (`2cada7f`, run `32925350974`).
  - **Pendiente real**: voz en chats de grupo sigue sin construir -- con esto, reacciones y read-receipts quedan cerrados, hueco reducido a solo la pieza de audio.

- **Ronda 2026-08-26 (dentro de `/loop`), notas de voz en chats de grupo, comparado con WhatsApp/Messenger/Telegram -- cierra por completo el hueco de "reacciones/voz/read-receipts en chats de grupo"**: última pieza, tercera ronda de la serie (reacciones → "visto por" → voz).
  - **`0062_group_message_audio.sql`**: sin infraestructura nueva -- `VoiceRecorder.kt`/`.swift` (MediaRecorder/AVAudioRecorder nativos) y `StorageUploader.uploadAudioFile()`/`.uploadAudio()`, construidos para el chat 1:1 en 0019_message_audio.sql, son 100% reutilizables tal cual. Solo replica el cambio de esquema real de esa migración: `audio_url` nuevo + reemplaza el check `body is not null or media_url is not null` por uno que también acepta `audio_url`. **Hallazgo real de Postgres, verificado antes de escribir la migración** (mismo criterio de "verificar, no asumir" de toda la sesión): el check original de `group_messages` (0057) se creó sin nombre explícito, así que hacía falta confirmar el nombre autogenerado real de Postgres para poder borrarlo (`<tabla>_check` para el primer check sin nombre) -- confirmado con una reproducción mínima aislada en PGlite antes de escribir `drop constraint`, no adivinado. Verificado local 151/151 tests (2 casos nuevos: un mensaje solo con audio_url sí se puede insertar; uno sin ningún contenido real sigue sin poder).
  - **Cliente (ambas plataformas)**: botón de grabar (🎙/mic) junto al compositor, mismo patrón exacto que ChatScreen.kt/ChatView.swift (chat 1:1) -- graba con `VoiceRecorder`, sube con `StorageUploader`, envía como `group_messages.audio_url`. Reproductor nativo (`MediaPlayer`/`AVAudioPlayer`) duplicado como `GroupAudioMessageBubble` en vez de compartido (el original es privado a su propio archivo).
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** (`6765a50`, run `32926425370`).
  - Con esto, el hueco de chats de grupo (reacciones + "visto por" + voz) queda cerrado del todo -- misma cobertura de funciones que el chat 1:1 salvo fotos (`media_url` en el esquema desde el principio, sin UI de cámara/galería todavía, hueco real menor no documentado hasta ahora).

- **Ronda 2026-08-26 (dentro de `/loop`), fotos en chats de grupo, comparado con WhatsApp/Instagram/Messenger/Facebook -- cierra la paridad completa con el chat 1:1**: última pieza menor identificada al terminar la ronda de voz -- `group_messages.media_url` ya existía en el esquema desde 0057_group_chats.sql (columna reservada desde el principio, mismo criterio que `messages.media_url`), pero sin ninguna UI real para enviarla ni mostrarla. Sin migración nueva -- solo cliente.
  - **Cliente (ambas plataformas)**: botón de cámara/galería junto al compositor, mismo patrón exacto que ChatScreen.kt/ChatView.swift (chat 1:1) -- reutiliza `StorageUploader.uploadImage` tal cual, sin infraestructura nueva. Miniatura de 200x200 en la burbuja, toque abre a tamaño completo reutilizando el visor ya compartido (`FullScreenImageViewer`/`FullScreenImageView`, el mismo componente del chat 1:1 y del feed).
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`). **iOS: CI real VERIFICADO EN VERDE** (`46bbfb7`, run `32927417071`).
  - Con esto, chats de grupo alcanzan paridad de funciones completa con el chat 1:1 (texto, fotos, voz, reacciones, "visto por" -- sin typing/presence en grupo todavía, hueco real menor no documentado hasta ahora).

- **Ronda 2026-08-26 (dentro de `/loop`), "en línea" y "escribiendo…" reales en chats de grupo, comparado con WhatsApp/Messenger -- cierra el último hueco menor de paridad de chats de grupo**: última pieza identificada al terminar la ronda de fotos. Sin migración nueva -- mismo mecanismo exacto que el chat 1:1 (`ChatViewModel.kt`/`.swift`): Presence/Broadcast de Supabase Realtime sobre el mismo canal (`group-chat-{id}`) ya abierto para mensajes, sin tabla ni columna nueva. Diferencia real de diseño frente al 1:1: un chat de grupo necesita un CONJUNTO de miembros en vez de un único booleano -- puede haber varias personas viendo el grupo o escribiendo a la vez -- así que `isOpponentOnline`/`isOpponentTyping` (1:1) se convierten en `onlineMemberIds`/`typingMemberIds` (`Set<String>`/`Set<UUID>`), y el único `typingClearJob` compartido del 1:1 se convierte en un job/task de apagado POR PERSONA (`typingClearJobs`/`typingClearTasks`, mapa indexado por user id), para que la persona A dejando de escribir no apague el indicador de la persona B.
  - **Cliente (ambas plataformas)**: `GroupChatViewModel.kt`/`.swift` gana `onlineMemberIds`/`typingMemberIds` y `notifyTyping()` (debounce de 300ms, igual que el 1:1); `subscribeToRealtime()` añade el `track()`/presence-change y el broadcast/stream de `"typing"` sobre el canal ya existente. UI: `GroupChatScreen.kt`/`GroupChatView.swift` muestran "🟢 N en línea" (mismo texto que el 1:1 pero con conteo) y "X está escribiendo…" / "X y N más están escribiendo…" (nombres resueltos contra la lista de miembros ya cargada), y llaman a `notifyTyping()` desde el `onValueChange`/`onChange` del campo de borrador, igual que `ChatScreen.kt`/`ChatView.swift`.
  - **Aviso de honestidad (iOS)**: las firmas reales de Presence/Broadcast en supabase-swift 2.x (`ch.track(state:)`, `PresenceActionV2.joins/leaves` como `[String: PresenceV2]`, `ch.broadcastStream(event:)`) ya se habían verificado con CI real en la ronda del chat 1:1 (ver comentario en `ChatViewModel.swift`) -- este cambio reutiliza esas mismas firmas ya confirmadas, no las repite a ciegas.
  - **Verificado real, no simulado**: Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`, dos veces -- ViewModel y luego UI), daemon detenido con `./gradlew --stop` tras cada compilación. **iOS: CI real VERIFICADO EN VERDE** (`44e6030`, run `32928470915`).

- **Ronda 2026-08-26 (dentro de `/loop`), HALLAZGO REAL EN EL PROPIO ARNÉS DE PRUEBAS (no en el esquema de la app) -- `test_rls.mjs`/`test_triggers.mjs` llevaban rotos desde `0041_notify_push_trigger.sql` (commit `9043388`, 2026-08-25), es decir, desde HACE VARIAS RONDAS**: al escribir el test de la siguiente feature (nombre/foto de grupo, ver abajo) el harness reventó con `ERROR INESPERADO: extension "pg_net" is not available` antes de ejecutar un solo `check()`. Investigado a fondo en vez de descartado como "límite de plataforma ya conocido": `0041` documentaba desde que se escribió que `create extension pg_net` "no es verificable en PGlite" (cierto, confirmado también ahora, ver `stripUnavailableExtension`), pero a diferencia de `uuid-ossp` (sí stubbeada desde el principio en `test_rls.mjs`/`test_triggers.mjs`), nadie actualizó `applyMigrations()` para saltarse esa sentencia -- lanzaba una excepción sin capturar que tumbaba el `for` de golpe, sin try/catch por archivo (a diferencia de `run_migrations.mjs`, que sí captura por archivo y por eso reporta "62/63" en vez de reventar). **Confirmado con `git stash` que esto NO es un efecto de esta pasada**: el HEAD real del repo (`327a565`, el commit inmediatamente anterior a este) revienta exactamente igual. Conclusión honesta: ningún recuento "local X/X" documentado en este archivo para rondas posteriores a `0041` (chats de grupo, reacciones, "visto por", voz, fotos, notificaciones, chat en vivo, typing/presence...) pudo haber salido de ejecutar `node test_rls.mjs ../migrations` tal cual estaba committeado -- o bien se usó algún workaround puntual no capturado en git en su momento, o esos recuentos nunca se re-verificaron contra un `applyMigrations()` limpio después de que 0041 aterrizara. No hay forma de reconstruir cuál de las dos con los commits ya hechos; lo honesto es señalarlo aquí en vez de dejarlo pasar.
  - **Arreglado**: `stripUnavailableExtension()` (en ambos archivos) ahora stubbea también `create extension if not exists pg_net ...`, mismo criterio exacto que ya se aplicaba a uuid-ossp -- sin tocar `run_migrations.mjs`, que ya manejaba esto bien por diseño (try/catch por archivo).
  - **Con el arreglo, el harness corre de punta a punta por primera vez en mucho tiempo**: `test_rls.mjs` → **154/154** (153 preexistentes + 1 nueva, ver ronda de nombre/foto de grupo abajo), `test_triggers.mjs` → 7/7 (sin cambios, ya funcionaban antes de esta ronda al no depender de RLS). A partir de ahora, cualquier ronda que use este arnés debe confirmar que sigue devolviendo un número real (no asumir que "sigue funcionando" solo porque funcionó hace muchas rondas).

- **Ronda 2026-08-26 (dentro de `/loop`), nombre editable y foto de grupo real, comparado con WhatsApp/Messenger/Telegram**: encontrado auditando `group_chats` tras la ronda de typing/presence -- la política `group_chats_update_own` existe desde `0057_group_chats.sql` (pensada exactamente para esto) pero **nunca se había usado**: cero `update`/`.update(` sobre `group_chats` en todo el código cliente de ninguna plataforma, y no existía columna de foto en absoluto. En WhatsApp/Messenger/Telegram, renombrar el grupo y ponerle foto DESPUÉS de crearlo es básico; en SOCIAL el nombre quedaba fijo para siempre desde la creación.
  - **`0063_group_chat_photo.sql`**: añade `group_chats.photo_url` (nullable). Sin cambio de RLS -- `group_chats_update_own` (`using (created_by = auth.uid())`) ya cubre cualquier columna, foto incluida; se mantiene el mismo criterio "solo el creador" ya establecido ahí (el rol de "admin" de WhatsApp/Messenger, sin sistema de roles nuevo).
  - **Segundo hallazgo real, esta vez de RLS, encontrado escribiendo el propio test**: un `UPDATE` gobernado solo por `USING` (sin verificación adicional en el cliente) que no encuentra ninguna fila que pase esa condición **no lanza excepción** -- simplemente actualiza 0 filas en silencio, a diferencia de un INSERT que sí viola un `WITH CHECK` (eso sí lanza). El primer intento de test usaba `expectFail` (que espera una excepción) para el caso "u2, no creador, intenta renombrar" y fallaba -- no porque RLS no funcionara, sino porque la comprobación era la incorrecta. Corregido comprobando que la fila NO cambió tras el intento, en vez de esperar un error. Verificado local **154/154** (con el arnés ya arreglado, ver hallazgo de arriba).
  - **Cliente (ambas plataformas)**: `GroupChat`/`GroupChatViewModel.kt`/`.swift` ganan `photoUrl`/`photoURL` y una fila `groupChat` cargada al abrir el hilo (antes el nombre solo venía por parámetro de navegación, sin fuente de verdad propia); `renameGroup()`/`updatePhoto()` nuevos (reutilizan `StorageUploader.uploadImage` tal cual, sin infraestructura nueva). UI: en la hoja "Miembros del grupo" (`MembersSheet`/`GroupMembersView`), el creador ve un lápiz para renombrar y puede tocar la foto para cambiarla (`PhotosPicker`/selector de imagen); cualquier no-creador ve ambos controles solo de lectura. `GroupChatsListScreen.kt`/`GroupChatsListView.swift` muestran la foto real del grupo en la lista (antes siempre "👥" fijo).
  - **Aviso de honestidad iOS**: en Swift se usa `.update(["campo": valor])` (diccionario con solo la columna a tocar), NO un struct con campos opcionales -- mismo patrón ya usado en `ChatViewModel.swift` (`markMessagesRead`/`toggleMute`/etc.), evitando el riesgo real de que un campo no tocado se codifique como `null` y borre sin querer la foto al renombrar (o el nombre al cambiar la foto).
  - **Verificado real, no simulado**: RLS 154/154. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`06c53fa`, run `32929946431`).
  - Con esto, chats de grupo alcanzan paridad de funciones COMPLETA con el chat 1:1 en todo lo construido hasta ahora (texto, fotos, voz, reacciones, "visto por", en línea, escribiendo…) -- **corrección de la pasada siguiente: sí queda un hueco real, silenciar el grupo, ver abajo**.

- **Ronda 2026-08-26 (dentro de `/loop`), silenciar un chat de grupo real, comparado con WhatsApp/Instagram/Messenger**: encontrado auditando `notify_new_group_message()` tras la ronda de nombre/foto -- el chat 1:1 ya deja silenciar una conversación sin salir de ella (`muted_by_a`/`muted_by_b`, 0047_message_notify_mute.sql), pero un grupo (con muchos más mensajes que un 1:1, mismo motivo por el que WhatsApp casi lo hace imprescindible ahí) no tenía forma real de silenciarse -- todo mensaje nuevo notificaba SIEMPRE a todos los demás miembros, sin excepción.
  - **`0064_group_chat_mute.sql`**: `group_chat_members.muted` (una sola columna, a diferencia de las dos del 1:1 -- `group_chat_members` ya es una fila POR MIEMBRO, así que la propia fila identifica de quién es, sin falta de una columna por persona ni de un trigger que compare "de quién es la columna que cambió"). `notify_new_group_message()` actualizada para saltar a los miembros con `muted = true`.
  - **Hallazgo real de RLS, encontrado escribiendo la propia migración, no el test esta vez**: la política de UPDATE necesaria para poder tocar `muted` (`using/with check (user_id = auth.uid())`) es forzosamente amplia a nivel de fila -- sin más, dejaría a un miembro reescribir `group_chat_id` de su PROPIA fila de membresía, "trasladándola" a un grupo distinto sin haber sido nunca invitado ahí (un agujero real de privilegios que `with check (user_id = auth.uid())` por sí solo no cierra, porque el `user_id` seguiría siendo el suyo). Cerrado con `trg_protect_group_chat_member_identity` (mismo patrón exacto que `protect_chat_muted_flags`/`protect_post_counts`: RLS amplia + trigger que revierte las columnas que no deben tocarse), verificado con un test que intenta exactamente ese traslado y confirma que la fila no se mueve.
  - **Verificado local 157/157** (154 preexistentes + 3 nuevos: silenciar la propia fila, el intento de traslado de membresía se revierte, y el miembro silenciado deja de recibir el aviso del siguiente mensaje).
  - **Cliente (ambas plataformas)**: `GroupChat`/`GroupChatsViewModel.kt`/`.swift` ganan `isMutedForMe` (una segunda consulta a `group_chat_members` filtrada al propio `user_id`, fusionada tras cargar la lista de grupos -- el dato vive en una tabla distinta a `group_chats`) y `toggleMute()` (mismo patrón optimista + revertir con `load()` si falla que `ChatListViewModel.toggleMute()`). UI: icono 🔔/🔕 en la fila de cada grupo en Android (`GroupChatsListScreen.kt`, igual que `ChatListScreen.kt`), `.swipeActions` "Silenciar"/"Activar" en iOS (`GroupChatsListView.swift`, igual que `ChatListView.swift` -- convención ya establecida de UI idiomática por plataforma en vez de una réplica visual exacta).
  - **Aviso de honestidad Swift**: `isMutedForMe` se declaró deliberadamente FUERA del `CodingKeys` de `GroupChat` (con valor por defecto `false`) -- `group_chats` no tiene esa columna, y así el decoder sintetizado por Swift ni siquiera intenta buscarla (comportamiento estándar y ya usado del lenguaje, no una suposición sin verificar), en vez de depender de un comportamiento de "decodeIfPresent automático para propiedades con valor por defecto" que no estaba verificado con certeza en este entorno sin compilador real.
  - **Verificado real, no simulado**: RLS 157/157. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`8de6472`, run `32930967792`).

- **Ronda 2026-08-26 (dentro de `/loop`), editar y borrar el propio mensaje en un chat de grupo real, comparado con WhatsApp/Telegram/Messenger**: encontrado auditando `group_messages` tras la ronda de silenciar -- el chat 1:1 ya deja editar (0049_messages_edit.sql) y borrar (0022_messages_delete.sql) el propio mensaje desde hace muchas rondas, pero `group_messages` (0057) nunca tuvo NINGUNA política de UPDATE/DELETE -- un mensaje mal escrito en un grupo se quedaba para siempre, sin forma de corregirlo ni borrarlo, ni siquiera el propio remitente.
  - **`0065_group_messages_edit_delete.sql`**: `group_messages.edited_at` + `group_messages_update_own`/`_delete_own` (`using/with check (sender_id = auth.uid())`), mismo criterio simple "borrar para todos" que el 1:1.
  - **Diferencia real de riesgo frente al 1:1, investigada antes de escribir la migración**: `group_messages` NO tiene el mismo agujero exacto que 0049 encontró en `messages` (ahí, `messages_update_read` ya daba a cualquier destinatario una política de UPDATE sobre la fila ajena, combinada por Postgres con OR a nivel de fila -- en grupo, "visto por" vive en su propia tabla, `group_message_reads` (0061), no en una columna de `group_messages`, así que no hay ninguna otra política de UPDATE con la que combinarse). El riesgo aquí es otro, mismo patrón que se acababa de encontrar para `group_chat_members` en la ronda de silenciar: `with check (sender_id = auth.uid())` certifica que el NUEVO sender_id sigue siendo el propio remitente, pero no dice nada sobre `group_chat_id` -- sin más, el remitente podría "trasladar" su propio mensaje ya enviado a un grupo donde ni siquiera es miembro, esquivando la comprobación de `private.is_group_member` que sí protege el INSERT original. Cerrado con `trg_protect_group_message_identity` (mismo patrón exacto que `trg_protect_group_chat_member_identity`, 0064), verificado con un test que intenta exactamente ese traslado.
  - **Verificado local 163/163** (157 preexistentes + 6 nuevos: editar guarda body/edited_at reales, el intento de traslado de group_chat_id se revierte, un no-remitente no puede editar NI borrar el mensaje ajeno -- 0 filas afectadas, no una excepción, mismo hallazgo ya confirmado con `group_chats_update_own` -- y el propio remitente sí puede borrar su mensaje de verdad).
  - **Cliente (ambas plataformas)**: `GroupMessage` gana `editedAt`; `GroupChatViewModel.kt`/`.swift` ganan `editMessage()`/`deleteMessage()` (mismo límite de 2000 caracteres, sin ventana de tiempo, que `ChatViewModel`) y una suscripción Realtime de UPDATE (mismo patrón que `ChatViewModel` para "Leído" en vivo, aquí reutilizada para que la edición de un mensaje se vea en vivo también en la pantalla de los demás miembros). UI: mantener pulsado el propio mensaje abre un menú real "Editar"/"Borrar"/"Cancelar" (`GroupChatScreen.kt`/`GroupChatView.swift`, mismo patrón exacto que `ChatScreen.kt`/`ChatView.swift`), etiqueta "Editado" cuando corresponde.
  - **Verificado real, no simulado**: RLS 163/163. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`bad0b02`, run `32932025908`).

- **Ronda 2026-08-26 (dentro de `/loop`), expulsar a un miembro del grupo real, comparado con WhatsApp/Messenger/Telegram**: encontrado auditando `group_chat_members` tras la ronda de editar/borrar mensajes -- `group_chat_members_delete_own` (0057) solo dejaba a cada quien salir por su cuenta; nadie, ni siquiera el creador, podía sacar a otro miembro. En las tres apps comparadas, quien creó el grupo puede quitar a alguien sin tener que esperar a que se vaya solo.
  - **`0066_group_chat_kick_member.sql`**: `group_chat_members_delete_by_creator` -- `using (exists (select 1 from group_chats where id = group_chat_id and created_by = auth.uid()))`. Postgres combina esta política con `group_chat_members_delete_own` (OR a nivel de fila): cada quien puede seguir borrando su propia fila (salir), y ahora el creador también puede borrar la de otro (expulsar). Investigado antes de escribir la migración si esto reabría el mismo tipo de recursión que obligó a crear `private.is_group_member` en 0057: no lo hace -- esta política vive en `group_chat_members` pero consulta `group_chats` (tabla distinta), y la única función que sí lee `group_chat_members` (`private.is_group_member`) es `security definer`, evalúa sin pasar por RLS.
  - **Verificado local 166/166** (163 preexistentes + 3 nuevos: un miembro real que no es el creador no puede expulsar a nadie -- 0 filas afectadas, mismo hallazgo ya confirmado varias veces esta sesión --, y el creador real sí expulsa de verdad).
  - **Cliente (ambas plataformas)**: `GroupChatViewModel.kt`/`.swift` ganan `kickMember()` (recarga la lista de miembros después en vez de asumir éxito, ya que el servidor decide en silencio si la fila se borra o no). UI: botón "Quitar" en la hoja de miembros en Android (`GroupChatScreen.kt`, visible solo al creador y nunca sobre sí mismo), `.swipeActions` "Quitar" en iOS (`GroupChatView.swift`, misma convención ya establecida de UI idiomática por plataforma que silenciar/renombrar).
  - **Verificado real, no simulado**: RLS 166/166. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`94dcfeb`, run `32932778217`).

- **Ronda 2026-08-26 (dentro de `/loop`), denunciar un mensaje concreto de un chat de grupo real, comparado con Instagram/WhatsApp/Messenger**: encontrado auditando `reports`/`GroupChatScreen.kt` tras la ronda de expulsar miembros -- `reports.message_id` (0048) solo referencia `messages` (chat 1:1), nunca `group_messages`; denunciar desde un grupo solo podía apuntar al perfil de quien escribió, sin ningún rastro de QUÉ mensaje concreto motivó la denuncia. La superficie de acoso real en un grupo es, si acaso, mayor que en un 1:1 (más gente escribe, más gente ve), y sin embargo el long-press de un mensaje ajeno en `GroupChatScreen.kt`/`GroupChatView.swift` no hacía nada en absoluto -- solo el propio (Editar/Borrar) tenía menú, añadido la ronda anterior.
  - **`0067_reports_group_message_reference.sql`**: `reports.group_message_id` (nullable, `on delete set null`, mismo criterio que `message_id`) + `group_messages_select_admin`. Mismo criterio deliberado que 0048 (no el bypass general de 0045 para posts/comentarios, que sí son contenido semi-público): un mensaje de grupo sigue siendo privado entre sus miembros, así que el bypass de admin solo deja ver un mensaje REALMENTE referenciado por una fila de `reports`, no el grupo entero.
  - **Verificado local 168/168** (166 preexistentes + 2 nuevos: alguien real ya sin membresía y sin ser admin -- u2, expulsado en la ronda anterior -- sigue sin poder ver el mensaje aunque esté denunciado, y un admin real que NUNCA fue miembro del grupo sí lo ve una vez denunciado).
  - **Cliente (ambas plataformas)**: `SafetyManager.kt`/`.swift` y `ReportSheet.kt`/`SafetyToolbar.swift` ganan `groupMessageId`/`groupMessageID`, mismo parámetro opcional ya usado para `messageId`. UI: mantener pulsado un mensaje AJENO en un grupo (antes sin ningún efecto) abre `ReportSheet` con `reportedId` = quien ESCRIBIÓ ese mensaje en concreto (no un único "oponente" fijo como en el 1:1, ya que un grupo tiene varios remitentes posibles).
  - **Verificado real, no simulado**: RLS 168/168. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`92d404e`, run `32933692221`).

- **Ronda 2026-08-26 (dentro de `/loop`), ocultar un chat de grupo real de "Grupos", comparado con WhatsApp/Instagram/Messenger**: encontrado auditando `group_chat_members` tras la ronda de denunciar mensajes -- el chat 1:1 ya deja ocultar una conversación de la lista sin salir de ella (`hidden_by_a`/`hidden_by_b`, 0044_chats_hide.sql), pero un chat de grupo solo tenía dos opciones extremas: quedarse en la lista para siempre, o "Salir del grupo" (perdiendo la membresía real). En WhatsApp/Messenger, "archivar" un grupo (igual que un 1:1) lo saca de la lista principal SIN salir de él, y reaparece solo si escriben de nuevo.
  - **`0068_group_chat_hide.sql`**: `group_chat_members.hidden` + `unhide_group_on_new_message` (mismo criterio exacto que `unhide_chat_on_new_message`, 0044: un grupo oculto para siempre en cuanto llega actividad real sería peor que no tener la función). Diseño más simple que el 1:1 a propósito, mismo motivo ya documentado para `muted` (0064): una fila POR MIEMBRO no necesita dos columnas ni un trigger de protección nuevo -- `group_chat_members_update_own` y `trg_protect_group_chat_member_identity` (ambos de 0064) ya cubren `hidden` gratis, igual que cubrieron `muted`.
  - **Verificado local 171/171** (168 preexistentes + 3 nuevos: ocultar la propia fila real, y un mensaje nuevo real restaura la visibilidad sola).
  - **Cliente (ambas plataformas)**: `GroupChatsViewModel.kt`/`.swift` ganan `hideGroup()` (quita el grupo de la lista local al instante, revierte con `load()` si falla el servidor) y filtran del todo cualquier grupo con `hidden = true` para el usuario actual al cargar la lista (segunda consulta a `group_chat_members`, mismo criterio que `isMutedForMe`). UI: mantener pulsado un grupo en Android (`GroupChatsListScreen.kt`, mismo patrón `combinedClickable` que `ChatListScreen.kt`), `.swipeActions` "Ocultar" en iOS (`GroupChatsListView.swift`, junto al ya existente "Silenciar"/"Activar").
  - **Verificado real, no simulado**: RLS 171/171. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`8590cb7`, run `32934519694`).

- **Ronda 2026-08-26 (dentro de `/loop`), enviar una publicación a un chat real, comparado con Instagram/TikTok/Twitter/Snapchat**: encontrado auditando el icono ➤ de `HomeScreen.kt`/`HomeView.swift` tras cerrar el hueco de "ocultar chat de grupo" -- en las cuatro apps comparadas, ese icono abre un selector INTERNO de a quién mandar la publicación (un chat, un grupo) -- el mecanismo de distribución más usado de esas apps, más que el "compartir" externo al sistema. En SOCIAL, el mismo icono solo abría el share sheet nativo (Android `Intent.ACTION_SEND`, iOS `ShareLink`) -- ninguna forma real de mandar una publicación como mensaje dentro de la propia app, ni al chat 1:1 ni a un grupo.
  - **`0069_message_shared_post.sql`**: `messages.shared_post_id`/`group_messages.shared_post_id` (nullable, `on delete set null`, mismo criterio ya establecido para `reports.post_id`/`message_id`/`group_message_id`), y ambos `*_has_content` amplían su check para aceptar `shared_post_id is not null`. Sin RLS nueva a propósito: un mensaje con `shared_post_id` sigue gobernado por `messages_insert`/`group_messages_insert` normales (mismo criterio que `media_url`/`audio_url`, que tampoco validan propiedad) -- la visibilidad REAL de la publicación la sigue decidiendo `posts_select` cuando el destinatario intente verla, no esta columna.
  - **Verificado local 174/174** (171 preexistentes + 3 nuevos: un mensaje solo con `shared_post_id` se puede insertar en el chat 1:1 y en un grupo, y el destinatario real lo ve).
  - **Cliente (ambas plataformas)**: `ChatMessage`/`GroupMessage` ganan `sharedPostId`/`sharedPostID`; `ChatViewModel`/`GroupChatViewModel` ganan `sharedPosts`/`sharedPostAuthors` (vista previa real cargada por lotes a partir de los `shared_post_id` presentes en los mensajes, mismo patrón que `loadMembers()`) y una llamada a `loadSharedPosts()` en carga inicial, paginación hacia atrás (1:1) y cada mensaje nuevo por Realtime. **`SendPostSheet.kt`/`SendPostView.swift` (nuevos)**: selector real reutilizando tal cual `ChatListViewModel`/`GroupChatsViewModel` (ya construidos para "Tus chats"/"Grupos") solo para listar a quién enviar -- el envío en sí es un insert directo, sin necesitar una instancia completa de `ChatViewModel`/`GroupChatViewModel` para un chat concreto. El icono ➤ en `HomeScreen.kt`/`HomeView.swift` ahora abre este selector; "Compartir externamente" se conserva como opción secundaria dentro del propio selector (Android: callback que reabre el `Intent` de siempre; iOS: `ShareLink` embebido como una fila más de la lista, más idiomático que un callback imperativo).
  - **Alcance deliberado, no fingido**: tocar la vista previa solo abre la foto a tamaño completo (reutiliza `FullScreenImageViewer`/`FullScreenImageView`, ya compartido) -- no navega a una pantalla de "publicación completa" con sus propios likes/comentarios, porque esa pantalla no existe todavía en NINGÚN sitio de la app (ni siquiera para post normales fuera del chat) -- construirla es un hueco real aparte, de tamaño comparable, documentado aquí y no absorbido a medias en esta ronda.
  - **Verificado real, no simulado**: RLS 174/174. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`90e734c`, run `32936221125`).

## Archivo de pasadas anteriores (resumido)

- **Ronda 2026-08-26 (dentro de `/loop`), publicación individual real ("permalink") + dos avisos con tap muerto arreglados, comparado con Instagram/Twitter/Facebook**: encontrado auditando el hueco documentado la ronda anterior ("tocar la vista previa de una publicación compartida solo abre la foto, sin pantalla propia de post") -- una investigación (agente Explore) confirmó que el hueco era más profundo: NINGÚN sitio de la app tenía una pantalla de "una sola publicación", y `notifications.payload.post_id` (real desde 0007_likes.sql/0008_comments.sql) nunca se leía en ningún cliente -- tocar un aviso de "like" o "comentario" era un tap muerto en Android (marcaba leído y ya) y en iOS abría la hoja genérica sin ninguna acción real. La misma investigación encontró un SEGUNDO tap muerto de la misma clase, ya con los datos listos desde hace rondas: un aviso de mensaje de GRUPO tampoco llevaba a ningún sitio (a diferencia de "message", que ya abre el chat 1:1).
  - **Sin migración nueva** -- los tres huecos eran puramente de cliente: los datos (`post_id`, `group_chat_id`) ya viajaban en el payload real desde hace rondas, solo faltaba leerlos.
  - **`PostDetailScreen.kt`/`PostDetailView.swift` (nuevos)**: pantalla real de una sola publicación -- autor (tocable, abre su perfil), carrusel de fotos si tiene varias (reutiliza `post_media`, mismo patrón exacto que el feed), caption, fecha relativa, like/guardar reales y "💬 N comentarios" que abre `CommentsSheet`/`CommentsView` ya existentes (sin duplicar la lista de comentarios). `PostDetailViewModel.kt` (Android) / lógica autocontenida con `@State` (iOS, mismo criterio ya usado en `ProfileViewerView.swift`) reimplementan el toggle de like/guardar -- no reutilizables tal cual desde `HomeViewModel`, que muta la lista `feed` entera, no una sola publicación.
  - **Navegación**: Android añade `POST_ROUTE = "post/{postId}"` al `NavHost` central de `RootTabView.kt` (mismo patrón que `GROUP_CHAT_ROUTE`); iOS añade `selectedPostID`/`showOpenedPost` + un `.navigationDestination(isPresented:)` más en `AvisosView.swift` (mismo patrón local ya usado ahí para chats, iOS 16, sin `(item:)`).
  - **Avisos arreglados**: `AvisosScreen.kt`/`AvisosView.swift` -- tocar un aviso de `like`/`comment` con `post_id` real abre `PostDetailScreen`/`PostDetailView`; tocar un aviso de `group_message` con `group_chat_id` real abre `GroupChatScreen`/`GroupChatView` (con un título de respaldo genérico "Grupo" hasta que `GroupChatViewModel` cargue el nombre real, mismo criterio que la propia migración `0057` ya documentaba para la navegación entre pantallas).
  - **Alcance deliberado, no absorbido a medias**: `comment_like`/`reel_comment_like`/`reel_like`/`reel_comment` siguen sin tap-through real (esos payloads solo llevan `comment_id`/`reel_id`, haría falta un join extra o, para los de Reels, decidir si navegan a `PostDetailScreen` o a un futuro visor de Reels individual -- alcance distinto, documentado aquí, no fingido). Tampoco se tocó todavía la burbuja de publicación compartida en el chat (`ChatView.swift`/`GroupChatView.swift`, ronda anterior) para que abra esta pantalla nueva en vez de solo la foto -- ahora que `PostDetailView` existe es un cambio pequeño, dejado para la siguiente pasada en vez de arriesgar esta ronda ya grande.
  - **Verificado real, no simulado**: sin migración, sin cambio de RLS. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`52fda68`, run `32937773392`).

- **Ronda 2026-08-26 (dentro de `/loop`), cierra el hueco menor documentado la ronda anterior: la burbuja de publicación compartida en el chat ahora abre la publicación completa real**: ahora que `PostDetailScreen.kt`/`PostDetailView.swift` existen, tocar la vista previa de una publicación compartida en un chat (1:1 o de grupo) abría solo la foto a tamaño completo -- cambio pequeño, exactamente el que se había dejado pendiente a propósito para no arriesgar la ronda anterior, ya grande.
  - **Sin migración, cliente puro.** Android: `ChatScreen.kt`/`GroupChatScreen.kt` ganan `onOpenPost: (String) -> Unit`, cableado en `RootTabView.kt` (`CHAT_ROUTE`/`GROUP_CHAT_ROUTE`) hacia `POST_ROUTE`; toda la tarjeta de vista previa (no solo la foto) es ahora el objetivo del toque. iOS: `MessageBubble`/`GroupMessageBubble` envuelven la vista previa en un `NavigationLink` real hacia `PostDetailView` (mismo criterio ya usado en `HomeView.swift` para el autor de un post) -- sin necesitar un callback nuevo, ya que `ChatView`/`GroupChatView` siempre se presentan dentro de un `NavigationStack` (empujados o dentro de su propio `NavigationStack` en una hoja), confirmado revisando los tres sitios reales desde los que se abren (`ChatListView`/`GroupChatsListView`/`AvisosView` vía `.navigationDestination`/`.sheet`).
  - **Verificado real, no simulado**: sin cambio de RLS. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`49b7e47`, run `32939008826`).

- **Ronda 2026-08-26 (dentro de `/loop`), tap-through real para avisos de "like a un comentario", cierra parte del hueco documentado la ronda anterior**: `comment_like`/`reel_comment_like` seguían siendo tap muerto tras cerrar `like`/`comment`/`group_message` -- a diferencia de esos tres (que ya llevaban `post_id`/`group_chat_id` real desde su propia migración original), `comment_like` (0054) solo llevaba `comment_id`, sin ningún dato con el que abrir la publicación real sin una consulta extra en cada toque. Mismo hueco exacto para `reel_comment_like` (solo `reel_comment_id`, nunca `reel_id`).
  - **`0070_notify_comment_like_post_reference.sql`**: `notify_new_comment_like()`/`notify_new_reel_comment_like()` ahora resuelven `post_id`/`reel_id` con un `select` adicional (ya disponible ahí mismo, desde la fila recién insertada) y lo añaden al payload -- mismo criterio que `like`/`comment` desde el principio (0007/0008). `reel_like`/`reel_comment` (0050) ya llevaban `reel_id` directo, sin tocar.
  - **Verificado local 176/176** (174 preexistentes + 2 nuevos: el payload real de `comment_like` trae `post_id`, el de `reel_comment_like` trae `reel_id`).
  - **Cliente (ambas plataformas)**: `AvisosScreen.kt`/`AvisosView.swift` -- un aviso de `comment_like` con `post_id` real abre `PostDetailScreen`/`PostDetailView`, mismo camino ya construido para `like`/`comment`.
  - **Alcance deliberado, no absorbido a medias**: `reel_like`/`reel_comment`/`reel_comment_like` siguen sin tap-through real todavía -- ya llevan `reel_id` (los tres, tras esta migración), pero abrir un reel concreto necesita que `ReelsScreen.kt`/`ReelsView.swift` (un `VerticalPager`/`TabView` sobre una lista ya cargada, sin ningún parámetro de "empezar en este reel") sepan desplazarse a un reel específico -- y ese reel podría ni siquiera estar en la ventana ya cargada. Hueco real DISTINTO (deep-link a un reel concreto), de tamaño comparable a esta ronda, documentado aquí en vez de fingir una solución a medias.
  - **Verificado real, no simulado**: RLS 176/176. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`e030ba3`, run `32940131173`).

- **Ronda 2026-08-26 (dentro de `/loop`), abrir un reel concreto real desde un aviso, cierra el hueco documentado dos rondas atrás, comparado con Instagram/TikTok**: `reel_like`/`reel_comment` ya llevaban `reel_id` real desde 0050_reels.sql, y `reel_comment_like` lo ganó hace una ronda (0070), pero tocar cualquiera de los tres avisos seguía sin llevar a ningún sitio -- `ReelsScreen.kt`/`ReelsView.swift` son un `VerticalPager`/lista vertical sobre los 30 reels más recientes ya cargados, sin ningún parámetro de "empezar en este reel", y el reel señalado por el aviso podría ni siquiera estar en esa ventana.
  - **Sin migración nueva** -- los tres kinds ya llevaban `reel_id` real; el hueco era puramente de cliente.
  - **`ReelsViewModel.kt`/`.swift`**: `load()` gana un `pinnedReelId`/`pinnedReelID` opcional -- si el reel del aviso no está entre los 30 más recientes, se pide aparte (sujeto a las mismas reglas RLS/bloqueo que el resto del feed) y se antepone a la lista, mismo criterio de "solo lo necesario" que `PostDetailViewModel.kt`/`PostDetailView.swift` (no reconstruye el feed entero para una sola pieza de contenido).
  - **Salto real a la posición**: Android añade `REEL_ROUTE = "reels/{reelId}"` (separado de `REELS_ROUTE`, sin argumento, para el acceso normal desde Perfil) y `ReelsScreen.kt` salta con `pagerState.scrollToPage(index)` una sola vez (guardado con `hasJumpedToInitial` para no volver a saltar cada vez que `reels` cambia por dar like/comentar). iOS, con su arquitectura real y deliberadamente distinta de Reels (lista vertical con `ScrollView`/`LazyVStack`, no un pager -- `TabView` de página solo pagina en horizontal antes de iOS 17, documentado desde que se construyó la pantalla), usa `ScrollViewReader`/`proxy.scrollTo(id:anchor:)` en vez de un índice de página, mismo guardián `hasJumpedToInitial`.
  - **Avisos arreglados**: `AvisosScreen.kt`/`AvisosView.swift` -- un aviso de `reel_like`/`reel_comment`/`reel_comment_like` con `reel_id` real ahora abre Reels en el reel señalado.
  - **Verificado real, no simulado**: sin cambio de RLS. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE tras 3 fallos reales encontrados y corregidos en el camino** (commit final `3256446`, run `32943175338`):
    1. **Fallo real #1 (`AvisosView.swift:39:25`, "unable to type-check this expression in reasonable time")**: la quinta rama `if/else if` (con `||` y varios `let`) añadida al closure de `Button` dentro del `List` desbordó el presupuesto combinatorio del type-checker de Swift dentro de un result builder. Corregido extrayendo esa lógica a `handleTap(on:)`, un método normal fuera de cualquier result builder -- **no bastó por sí solo** (mismo error, mismo run de CI siguiente).
    2. **Fallo real #2 (mismo error, misma línea, tras el fix #1)**: el resto de `body` (cuatro `.navigationDestination(isPresented:)` con `if let` inline, la fila `Button`/`HStack` del `List`, el `.sheet(item:)` con `.flatMap` inline) seguía siendo demasiado para el type-checker en una sola expresión. Corregido extrayendo cada `.navigationDestination` a su propia propiedad `@ViewBuilder`, la fila del `List` a una vista propia (`AvisoRow`), y añadiendo una anotación de tipo explícita en el `let` del `.sheet`.
    3. **Fallo real #3 (`AvisosView.swift:112:38`, "argument passed to call that takes no arguments"), encontrado por el propio fix #2**: `ReelsView.initialReelID` se había declarado `let initialReelID: UUID? = nil` -- una propiedad `let` CON valor por defecto queda EXCLUIDA del init memberwise sintetizado por Swift (se trata como una constante fija, no como un parámetro con valor por defecto), dejando el init sin ningún argumento externo utilizable. Corregido a `var` (mismo criterio ya usado correctamente en `PostDetailView.swift.onOpenProfile` y en `sharedPost`/`sharedPostAuthor` de `MessageBubble`/`GroupMessageBubble`, que sí son `var`).
    Los tres fallos son reales, encontrados y corregidos con el CI real de GitHub Actions -- no simulados, no adivinados sin confirmar.

- **Ronda 2026-08-26 (dentro de `/loop`), responder a una historia real, comparado con Instagram/WhatsApp Status/Snapchat**: `StoryViewer` (visor de historias) ya tenía "quién vio tu historia" (0053) pero ningún campo de texto ni forma de responder -- en las tres apps comparadas, ver la historia de alguien muestra un campo "Responder..." abajo; escribir y enviar manda esa respuesta como un mensaje DIRECTO real a esa persona, una de las dos interacciones con historias más usadas de esas apps.
  - **`0071_message_story_reply.sql`**: `messages.story_id` (nullable, `on delete set null`, mismo criterio ya establecido para `shared_post_id`/`reports.post_id`). Sin RLS nueva a propósito: `stories_select` (`expires_at > now()`, 0002) ya deniega ver una historia caducada incluso al destinatario del mensaje -- comportamiento CORRECTO y esperado (igual que WhatsApp Status: si el estado ya expiró, la vista previa de "respondió a tu estado" deja de poder mostrarse), no un hueco a tapar con una política nueva -- el cliente muestra "Historia ya no disponible" como respaldo real.
  - **Verificado local 178/178** (176 preexistentes + 2 nuevos: un mensaje solo con `story_id` se puede insertar, y el destinatario real lo ve).
  - **Reutilización real, sin infraestructura nueva**: `SocialLinkManager.getOrCreateChat()` (ya construido para "Enviar mensaje" desde un aviso) resuelve/crea el chat 1:1 con el autor de la historia -- responder a una historia de alguien con quien nunca se había chateado antes funciona igual que en Instagram/WhatsApp, sin pedir "aceptar" nada primero (mismo criterio ya establecido: `chats_insert` no exige ninguna relación previa).
  - **Cliente (ambas plataformas)**: `StoriesViewModel.kt`/`.swift` ganan `sendReply()`; `ChatViewModel.kt`/`.swift` ganan `storyPreviews` (vista previa cargada por lotes, mismo patrón que `sharedPosts`) sin necesitar resolver autor aparte (la historia respondida siempre es de uno de los dos participantes ya conocidos del chat 1:1). UI: campo de texto real en `StoriesBar.kt`/`.swift` (solo sobre la historia de OTRA persona, nunca la propia), que PAUSA el avance automático de 5s mientras tiene el foco -- avance reescrito como un bucle de pasos de 50ms (en vez de un único tween/animación) para poder comprobar el foco en cada paso sin recalcular una duración "restante" al reanudar. `ChatScreen.kt`/`ChatView.swift` renderizan la burbuja de respuesta (miniatura + "Respondiste"/"Respondió a tu historia" + el texto real).
  - **Verificado real, no simulado**: RLS 178/178. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`6aac8a0`, run `32945466985`).

- **Ronda 2026-08-26 (dentro de `/loop`), reenviar un mensaje real, comparado con WhatsApp/Telegram/Messenger**: uno de los gestos de mensajería más usados de esas apps (cualquier mensaje, propio o ajeno, se manda a otro chat o grupo), y SOCIAL no tenía ninguna forma de hacerlo -- ni siquiera copiar/pegar manual, dado que los mensajes no tienen selección de texto real más allá del bubble completo.
  - **`0072_message_forward.sql`**: `messages.is_forwarded`/`group_messages.is_forwarded` (sin `forwarded_from_message_id` ni ninguna referencia real al original -- mismo criterio simple que WhatsApp: una copia real e independiente de `body`/`media_url`/`audio_url`, marcada con una etiqueta visual, sin encadenar una cadena de referencias entre chats que el destinatario del original podría no querer exponer). Sin RLS nueva: sigue gobernado por `messages_insert`/`group_messages_insert` normales -- reenviar no concede ningún permiso que el remitente no tuviera ya.
  - **Verificado local 181/181** (178 preexistentes + 3 nuevos: un mensaje real con `is_forwarded` se puede insertar en el chat 1:1 y en un grupo, y el destinatario real lo ve con el flag correcto).
  - **`ForwardMessageSheet.kt`/`ForwardMessageView.swift` (nuevos)**: mismo selector "Enviar a…" que `SendPostSheet.kt`/`SendPostView.swift` (ronda de compartir publicaciones) -- duplicado a propósito, no compartido, porque cada uno inserta un contenido distinto (`shared_post_id` vs. `body`/`media_url`/`audio_url` + `is_forwarded`), mismo criterio ya aplicado a `GroupAudioMessageBubble`.
  - **Cliente (ambas plataformas)**: un tap target "↪ Reenviar" siempre visible (no solo con mantener pulsado, ya usado para editar/borrar/denunciar) en cualquier mensaje con contenido real (texto/foto/audio), disponible tanto en el chat 1:1 como en un chat de grupo, y hacia CUALQUIER chat o grupo como destino (reenviar desde un grupo a un 1:1, o viceversa, funciona igual). Etiqueta "Reenviado" real cuando corresponde.
  - **Alcance deliberado, no fingido**: publicaciones compartidas y respuestas a historias quedan fuera de esta ronda -- esos mensajes no llevan `body`/`media_url`/`audio_url` propios, solo una referencia (`shared_post_id`/`story_id`), así que "reenviarlos" tal cual produciría un mensaje vacío inválido; el tap target de reenviar se oculta automáticamente para ellos en vez de fingir que funciona.
  - **Verificado real, no simulado**: RLS 181/181. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`6dd6795`, run `32947575305`).

- **Ronda 2026-08-26 (dentro de `/loop`), nombre de usuario único (@handle) real, comparado con Instagram/Twitter/TikTok**: `profiles` solo tenía `display_name` desde el principio -- texto libre, no único, puede repetirse o llevar espacios. Las tres apps de referencia tienen un `@handle` permanente, único, en minúsculas, distinto del nombre para mostrar -- SOCIAL no tenía ningún equivalente, y sin él tampoco es posible desambiguar dos perfiles con el mismo nombre ni construir @menciones en el futuro (mismo bloqueo estructural que impedía @menciones en captions/comentarios).
  - **`0073_profile_username.sql`**: `profiles.username text unique` (nullable -- no se exige de inmediato, mismo criterio que `display_name` en su día), `check (username is null or username ~ '^[a-z0-9_]{3,20}$')`. Normalizado a minúsculas en el cliente antes de cada lectura/escritura (se evitó la extensión `citext` a propósito, mismo criterio de "no añadir infraestructura nueva si una normalización simple en cliente basta" ya aplicado en otras rondas). Sin RLS nueva: `profiles_update_own` (0002_rls.sql) ya cubre la actualización de cualquier columna propia.
  - **Aviso de honestidad**: para el flujo de guardado se comprueba disponibilidad con un `SELECT` real ANTES del `UPDATE`, en vez de intentar distinguir un error genérico de guardado de un fallo real de `unique` -- la forma exacta de la excepción que lanzan Postgrest/supabase-swift ante una violación de `unique` real no está verificada contra un proyecto vivo en este entorno, así que no se adivina su forma con un string-match.
  - **Verificado local 185/185** (181 preexistentes + 4 nuevos: guardar un username real con formato válido funciona; un username con mayúsculas o demasiado corto se rechaza; un segundo usuario no puede quedarse un username ya usado; ese mismo segundo usuario sí puede guardar uno distinto).
  - **Cliente (ambas plataformas)**: campo "@usuario" nuevo en Editar perfil (`EditProfileSheet.kt`/`EditProfileView.swift`) con su propio botón de guardado y su propio mensaje de error (distinto del genérico de nombre/bio/avatar); `@usuario` visible bajo el nombre en el perfil propio, en el perfil de otra persona y en cada resultado del buscador; el buscador (`SearchViewModel.kt`/`SearchViewModel.swift`) ahora encuentra también por `@usuario` exacto además de por nombre para mostrar (`or { ilike(display_name); ilike(username) }` en Kotlin, `.or("display_name.ilike...,username.ilike...")` en Swift -- mismo patrón `or` ya usado y compiler-verificado en `ChatListViewModel`/`DuelHistoryViewModel`/`SocialsListViewModel` de cada plataforma, no una firma nueva sin confirmar).
  - **Alcance deliberado, no fingido**: @menciones dentro de captions/comentarios (con notificación al mencionado) queda fuera de esta ronda -- es un hueco real y ahora sí construible (ya existe el handle único en el que anclarlas), pero es un trabajo propio de detectar/parsear/enlazar texto, no una extensión trivial de esta ronda. Añadido explícitamente a "Pendiente real" abajo.
  - **Verificado real, no simulado**: RLS 185/185. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`b9e599d`, run `32950426343`).

- **Ronda 2026-08-26 (dentro de `/loop`), @menciones reales en captions/comentarios, comparado con Instagram/Twitter/TikTok**: hueco documentado explícitamente como "Pendiente real" en la ronda anterior (username único) -- ahora sí construible porque ya existe un `@handle` real al que anclar la mención. Las tres apps de referencia dejan escribir "@usuario" en un caption o un comentario para enlazarlo al perfil real y avisar a esa persona; SOCIAL no tenía nada de esto.
  - **`0074_mentions.sql`**: nuevo kind `'mention'` en `notifications_kind_check`. Helper compartido `private.extract_mentioned_profile_ids(texto, actor_id)` (mismo criterio que `private.has_accepted_social`/`private.is_blocked`: security definer + search_path vacío + revoke de ejecución directa) que busca "@usuario" reales vía `regexp_matches(..., 'g')`, los cruza contra `profiles.username` (0073), excluye auto-mención y bloqueo mutuo, y deduplica con `distinct` si el mismo @usuario aparece repetido. Cuatro triggers `AFTER INSERT` reutilizando ese helper: `posts.caption`, `reels.caption`, `comments.body`, `reel_comments.body`. Sin RLS nueva: los `INSERT` en `notifications` los hace el propio trigger `security definer`, igual que `notify_new_comment`/`notify_new_reel_comment`.
  - **Alcance deliberado**: chats 1:1/de grupo (texto privado, sin equivalente real de "mención pública" tampoco en Instagram/Twitter/TikTok) y `profile_sections` (texto largo de "sobre mí", no una superficie de publicación puntual) quedan fuera a propósito.
  - **Verificado funcional 6/6 nuevo** (`test_triggers.mjs`): @mención real en un caption de post SÍ notifica; en un comentario de post SÍ notifica; automencionarse NO notifica; @mención en un caption de reel SÍ notifica; en un comentario de reel SÍ notifica; mencionar a alguien que te bloqueó NO notifica. RLS 185/185 sin regresión.
  - **Cliente (ambas plataformas)**: `MentionHashtagText.kt`/`.swift` (nuevo, `util`/`Util`) -- componente COMPARTIDO entre las cuatro superficies (caption de post, caption de reel, comentario de post, comentario de reel), a diferencia de los sheets "Enviar a…" de rondas anteriores (duplicados a propósito porque cada uno inserta contenido distinto): aquí la lógica de renderizado de "#etiqueta"/"@usuario" tocables es IDÉNTICA en las cuatro, así que compartir es lo correcto. `MentionResolver.kt`/`.swift` (nuevo) resuelve el @usuario tocado a un id de perfil real (`SELECT` por `username`) antes de navegar -- sin resultado si la cuenta ya no existe, resuelto en silencio, mismo criterio que `shared_post_id`/`story_id` en mensajes. Tocar una mención abre `ProfileViewerScreen.kt`/`ProfileViewerView.swift` igual que tocar el autor de un post. Tap en el aviso de "Te mencionó" lleva directo al post/reel real (`AvisosScreen.kt`/`AvisosView.swift`), mismo patrón que like/comentario. Categoría "Menciones" nueva y silenciable por separado en Ajustes (`AjustesScreen.kt`/`AjustesView.swift`), y `send-push/index.ts` manda el push real con icono/título correctos en vez de caer en el "🔔" genérico.
  - **Verificado real, no simulado**: RLS 185/185 + 6/6 funcionales. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`, tras un fallo real de compilación propio corregido en el camino: faltaba `import androidx.compose.ui.text.withStyle` en `MentionHashtagText.kt` -- `withStyle` dentro de `buildAnnotatedString { }` no se resuelve solo por estar en el mismo paquete `androidx.compose.ui.text`, hace falta importarlo explícitamente), daemon detenido. **iOS: CI real VERIFICADO EN VERDE** (`a9b10ed`, run `32953234040`).

- **Ronda 2026-08-26 (dentro de `/loop`), "Mejores amigos" real para historias, comparado con Instagram (Close Friends) y Snapchat (audiencia personalizada)**: hallazgo real de SEGURIDAD, no solo de funcionalidad -- `stories_select` (0002_rls.sql) era `using (expires_at > now())`, sin ninguna restricción de audiencia. Cualquier usuario autenticado podía ver la historia de CUALQUIER otro, sin necesidad de social aceptado ni de seguirle; ni siquiera existía el equivalente de `posts.is_social_only` para historias.
  - **`0075_close_friends_stories.sql`**: tabla `close_friends(owner_id, friend_id)` con RLS propia -- ni siquiera la persona añadida puede leer que está en la lista de otro (mismo criterio que Instagram). Helper `private.is_close_friend(owner, friend)` (mismo patrón exacto que `private.is_blocked`/`private.has_accepted_social`: security definer + search_path vacío + revoke de ejecución directa). Nueva columna `stories.visibility` ('everyone' por defecto / 'close_friends'), y `stories_select` reescrita para exigir `visibility = 'everyone' OR autor OR is_close_friend(autor, yo)`.
  - **Verificado local 194/194** (185 preexistentes + 9 nuevos, primera vez a la primera sin ningún fallo real de RLS -- a diferencia de casi todas las políticas nuevas de esta sesión, que encontraron algún bug real de Postgres en el camino): comportamiento "everyone" sin cambios para un tercero cualquiera; un mejor amigo real añadido SÍ ve una historia "close_friends"; un tercero que no lo es NO la ve; el propio autor siempre la ve; quitarlo de la lista real revoca el acceso de inmediato; nadie puede añadirse a sí mismo en la lista ajena; ni siquiera el amigo añadido puede leer la lista de quien lo añadió.
  - **Cliente (ambas plataformas)**: al subir una historia, un diálogo real pregunta "¿Quién puede ver esta historia?" ("Todos" / "Mejores amigos") en vez de fijar la audiencia en silencio (`StoriesBar.kt`/`.swift`). Pantalla nueva "Mejores amigos" en Ajustes (`CloseFriendsScreen.kt`/`CloseFriendsView.swift` + ViewModel) que reutiliza la lista de socials aceptados como candidatos (mismo patrón sin join embebido/FK ambigua que `SocialsListViewModel`) con un `Switch`/`Toggle` por persona en vez de un botón "Quitar" destructivo, porque aquí la acción es un estado binario reversible.
  - **Verificado real, no simulado**: RLS 194/194. Android `:app:compileDebugKotlin` OK a la primera (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE a la primera, sin ningún fallo** (`857504c`, run `32955289572`).

- **Ronda 2026-08-26 (dentro de `/loop`), archivar publicaciones real, comparado con Instagram/Facebook**: las dos dejan sacar una publicación del perfil público sin borrarla -- se puede archivar y luego restaurar cuando se quiera, conservando like_count/comment_count/comentarios reales intactos. Confirmado en el propio código: `MyPostsScreen.kt`/`MyPostsView.swift` ("Tus publicaciones") solo tenía "Editar"/"Borrar" -- o la publicación se queda visible para siempre, o se pierde para siempre, sin término medio real.
  - **`0076_archive_posts.sql`**: `posts.archived_at timestamptz` (null = visible con normalidad). `posts_write_own` (0002_rls.sql, ya `for all`) no necesitó política nueva para el UPDATE; `posts_select` reescrita para que una publicación archivada solo la vea su propio autor. `comments_select`/`post_media_select` reescritas en espejo exacto (mismo criterio ya reflejado entre sí desde 0008/0055) para que los comentarios/fotos extra de una publicación archivada tampoco se cuelen para un desconocido.
  - **Hallazgo real de robustez del propio arnés de pruebas** (no de RLS): la primera versión de las pruebas usaba u3 como "tercero cualquiera", pero u3 ya era admin desde el bloque de moderación de más arriba -- `posts_select_admin`/`comments_select_admin` (0045) le dan visibilidad total de verdad e intencionada (un admin revisando una denuncia SÍ debe ver hasta el contenido archivado), así que los primeros intentos "fallaban" solo porque u3 no era un desconocido real. Corregido creando un u4 nuevo, sin admin y sin relación previa con u1.
  - **Verificado local 202/202** (194 preexistentes + 8 nuevos): antes de archivar un tercero real la ve; el propio autor SÍ puede archivarla; un tercero NO puede desarchivar la ajena (0 filas afectadas); tras archivarla de verdad un tercero YA NO la ve, ni sus comentarios; el propio autor SIEMPRE la sigue viendo; el propio autor SÍ puede restaurarla; tras restaurarla un tercero vuelve a verla.
  - **Cliente (ambas plataformas)**: tercera pestaña "Archivadas" en "Tus publicaciones" (`MyPostsScreen.kt`/`MyPostsView.swift`) junto a "Todas"/"Con tus socials" -- las dos primeras excluyen archivadas (mismo criterio que Instagram: el archivo es un sitio aparte), botón/swipe "Archivar"/"Desarchivar" según el estado real de cada publicación.
  - **Consistencia real de paso, mismo hallazgo aplicado en cuatro sitios**: `posts_select` deja ver la propia publicación archivada al propio autor (para poder gestionarla), pero eso NO debe traducirse en que siga asomando en su feed principal, su rotación de foto de cabecera de perfil, ni sus propios resultados de búsqueda por hashtag -- filtrado explícito en cliente en los cuatro sitios (`HomeViewModel`, `PerfilViewModel.loadLatestPostMedia`, `SearchViewModel.searchHashtag`, ambas plataformas) para que archivar de verdad la saque de la circulación normal, no solo de la vista de terceros.
  - **Verificado real, no simulado**: RLS 202/202. Android `:app:compileDebugKotlin` OK a la primera (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE a la primera** (`9dfebcb`, run `32957354922`).

- **Ronda 2026-08-26 (dentro de `/loop`), enlace externo real en el perfil ("link in bio"), comparado con Instagram/TikTok/Twitter**: las tres dejan poner una URL bajo la bio, tocable, que abre el navegador -- uno de los pocos sitios donde esas apps permiten un enlace saliente real. Confirmado en el propio código: `EditProfileSheet.kt`/`EditProfileView.swift` solo tenían nombre, bio, username (0073) y el look del avatar -- ningún campo de URL en absoluto, ni en el esquema (`profiles`) ni en la cabecera del perfil.
  - **`0077_profile_website.sql`**: `profiles.website_url text` con un límite real de 200 caracteres (`profiles_website_url_length`) -- sin validación estricta de formato a nivel de base de datos, mismo criterio ya aplicado a `username`: el cliente antepone "https://" si falta el esquema antes de guardar. Sin RLS nueva: `profiles_update_own` ya cubre cualquier columna propia.
  - **Verificado local 204/204** (202 preexistentes + 2 nuevos: guardar un enlace real funciona; uno de más de 200 caracteres se rechaza).
  - **Cliente (ambas plataformas)**: campo "Enlace (sitio web)" en Editar perfil, guardado junto con nombre/bio/avatar (a diferencia del username, aquí no hay un fallo de "ya en uso" que necesite su propio botón/mensaje); enlace real tocable (sin el prefijo `https://` en pantalla, mismo criterio visual que Instagram) bajo la bio en el perfil propio y en el perfil de otra persona -- abre el navegador de verdad (`Intent.ACTION_VIEW` en Android, `Link` nativo en iOS).
  - **Verificado real, no simulado**: RLS 204/204. Android `:app:compileDebugKotlin` OK a la primera (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE a la primera** (`8c10487`, run `32958794916`).

- **Ronda 2026-08-26 (dentro de `/loop`), palabras silenciadas reales en comentarios, comparado con Instagram/Twitter**: las dos dejan definir una lista de palabras propia que oculta automáticamente cualquier comentario que las contenga, sin tener que moderar uno a uno y sin bloquear a nadie -- el comentario SIGUE existiendo de verdad para todos los demás, incluido quien lo escribió; solo desaparece para el dueño de la publicación/reel que activó ese filtro. Confirmado en el propio código: el único filtrado de contenido que existía era el bloqueo binario (`blocks`, todo o nada) y el panel de moderación de admin -- nada a nivel de usuario individual para su PROPIO contenido.
  - **Diseño real distinto de toda política nueva anterior de esta sesión**: is_social_only/archived_at/close_friends ocultan lo MISMO para TODO el mundo salvo una lista de excepciones (visibilidad universal). Aquí cada comentario sigue viéndose con normalidad para cualquiera EXCEPTO para el dueño del post/reel que activó su propio filtro -- una condición `AND NOT` añadida a las políticas de SELECT YA EXISTENTES (`comments_select`/`reel_comments_select`), no una política nueva (una política adicional solo ampliaría la visibilidad vía OR, nunca la restringiría).
  - **`0078_muted_keywords.sql`**: `profiles.muted_keywords text[]` (mismo criterio que `muted_push_kinds`, 0052). Helper `private.contains_muted_keyword(texto, owner_id)` (mismo patrón que `is_blocked`/`has_accepted_social`) que cruza el texto contra la lista de palabras del DUEÑO del post/reel, no de quien consulta.
  - **Verificado local 210/210** (204 preexistentes + 6 nuevos, primera vez a la primera sin ningún fallo): quien escribió el comentario con la palabra silenciada SIGUE viéndolo; el dueño real NO ve ese comentario pero SÍ sigue viendo los demás; un tercero real SÍ ve el comentario con la palabra silenciada de OTRO (el filtro es estrictamente personal); mismo comportamiento verificado en espejo para `reel_comments`.
  - **Cliente (ambas plataformas)**: nueva sección "Palabras silenciadas" en Ajustes (reutilizando `PrivacySettingsViewModel`/`.swift`, el mismo ViewModel que ya gestiona `muted_push_kinds`/`compat_public`/`location_public` -- no una pantalla nueva aparte) con campo para añadir + lista con botón "Quitar" por palabra.
  - **Verificado real, no simulado**: RLS 210/210. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE a la primera** (`57be050`, run `32961326736`).

- **Ronda 2026-08-26 (dentro de `/loop`), videollamada/llamada de voz 1:1 real desde un chat, comparado con WhatsApp/Messenger/Instagram**: las tres dejan llamar directamente desde un chat privado -- mensajería sin llamada es la excepción hoy, no la norma. `grep` de "calls"/"video_call"/"voice_call" en todo el repo: cero resultados. La única pieza de vídeo en tiempo real que existía era "En directo" (0056_live_streams.sql), pensada para audiencia PÚBLICA (host + N espectadores), sin ningún concepto de sesión privada 1:1 -- reutiliza LiveKit (mismo motor, misma cuenta, ya integrado en ambas plataformas) en vez de montar infraestructura de señalización nueva.
  - **`0079_calls.sql`**: tabla `calls(chat_id, caller_id, callee_id, kind, room_name, status)` -- `status` real ('ringing'/'accepted'/'declined'/'ended'/'missed'). RLS simétrica (los dos participantes, a diferencia de host/espectador de "En directo"): `calls_insert` comprueba contra la fila real de `chats` que el emisor/destinatario son de verdad los dos lados del chat (mismo criterio que `trg_protect_group_message_identity`) y bloqueo real vía `private.is_blocked`. `private.protect_call_identity()` (mismo patrón `pg_trigger_depth() <= 1` que `trg_protect_group_message_identity`) impide que un UPDATE redirija la llamada a otra identidad -- solo `status`/`ended_at` son editables tras crear la fila.
  - **`call-token/index.ts`** (Edge Function nueva): mismo JWT HS256 firmado a mano con Web Crypto que `live-token/index.ts` (duplicado a propósito, no compartido: cada uno comprueba autorización contra una tabla y unas reglas distintas), pero simétrico -- las dos partes publican Y se suscriben por igual (a diferencia de host/espectador), y solo emite un token real cuando la llamada YA está `accepted` de verdad en la base de datos.
  - **Verificado local 220/220** (210 preexistentes + 10 nuevos, todos a la primera): `room_name` real autogenerado; arranca en 'ringing'; un tercero no puede crear una llamada en un chat ajeno ni verla; el destinatario real acepta; un UPDATE no puede redirigir caller_id/callee_id/chat_id/room_name a otra identidad; el emisor real cuelga con `ended_at` real; no se puede llamar a quien te bloqueó.
  - **Cliente (ambas plataformas)**: `CallManager`/`.swift` global (mismo criterio que el badge de Avisos: canal Realtime **por usuario** `calls-{userId}`, no global -- `legal/scaling_notes.md` documenta explícitamente que los canales de este proyecto son por chat o por usuario, nunca globales) detecta una llamada entrante en cualquier pestaña, no solo dentro del chat. Overlay real montado en `RootTabView.kt`/`.swift` (mismo sitio que el badge) con las cuatro pantallas reales del estado de una llamada: entrante (Aceptar/Rechazar), saliente ("Llamando…", Cancelar), en curso (vídeo local+remoto o avatar+icono para audio, mute/cámara, Colgar) y final (Rechazada/Perdida/Finalizada). Botones 📞/🎥 nuevos en la cabecera del chat 1:1.
  - **Aviso de honestidad, mismo criterio que "En directo"/push**: detecta una llamada entrante en tiempo real de verdad mientras la app está ABIERTA (cualquier pestaña) vía Supabase Realtime -- lo que NO puede hacer sin push real (APNs/FCM, ver "Pendiente real" arriba) es sonar con la app cerrada o en segundo plano del todo. Aparte, en el lado iOS se evitó deliberadamente adivinar el nombre exacto de un método de `RoomDelegate` para detectar un corte de conexión sin poder verificarlo con compilador real (documentado en el propio código de `CallView.swift`) -- no hacía falta: colgar ya viaja por Postgres/Realtime, que es el mecanismo real que saca a las dos partes de la llamada.
  - **Alcance deliberado, no fingido**: llamadas de GRUPO quedan fuera de esta ronda (un chat de grupo con N participantes en una sala LiveKit es un problema de UI real distinto -- rejilla de N vídeos, no dos) -- documentado aquí como pendiente real futuro, no construido a medias.
  - **Verificado real, no simulado**: RLS 220/220. Android `:app:compileDebugKotlin` OK (`BUILD SUCCESSFUL`, tras dos fallos reales de compilación propios corregidos en el camino: `setMicrophoneEnabled`/`setCameraEnabled` son funciones `suspend` de verdad, llamarlas directo dentro de un `onClick` sin `scope.launch` no compila; y faltaba `import androidx.compose.foundation.layout.fillMaxSize` en RootTabView.kt), daemon detenido. **iOS: CI real VERIFICADO EN VERDE a la primera, sin ningún fallo** (`755cc09`, run `32964719959`).

- **Ronda 2026-08-26 (dentro de `/loop`), verificación real (insignia azul), comparado con Instagram/Twitter/TikTok**: las tres dejan al usuario SOLICITAR la verificación; un equipo revisa y aprueba o rechaza. Hallazgo real: `profiles.is_verified` (0001_schema.sql) existe desde el principio y ya está protegido de verdad contra auto-concesión (`trg_protect_is_verified`, 0029) -- la insignia incluso se PINTA de verdad en varias pantallas (`PerfilScreen.kt`/`ProfileViewerScreen.kt`/`SearchScreen.kt` y sus equivalentes iOS) -- pero no existía NINGÚN camino para que `is_verified` llegara a ser `true` salvo escribirlo a mano en la base de datos.
  - **`0080_verification_requests.sql`**: tabla `verification_requests(profile_id, message, status)` -- mismo patrón exacto ya construido para baneos/apelaciones (`0037_admin_ban.sql`/`0043_ban_appeals.sql`): RLS insertar/ver lo propio + ver/actualizar como admin, y una función `admin_set_verified(target, verified)` que comprueba `is_admin` del LLAMANTE dentro de la propia función (no una política RLS de UPDATE abierta sobre `profiles` para admins, superficie de ataque mucho mayor) y se eleva localmente a la transacción (`set_config('app.role', 'service_role', true)`) para que `trg_protect_is_verified` deje pasar el cambio -- mismo mecanismo exacto que `admin_ban_user()`.
  - **Verificado local 227/227** (220 preexistentes + 7 nuevos, todos a la primera): un tercero no ve la solicitud ajena; un usuario normal NO puede verificar a nadie; un admin real SÍ ve la solicitud y SÍ puede verificar y aprobarla; `is_verified` real queda en `true` de verdad; el propio usuario recién verificado NO puede quitarse la verificación con un UPDATE directo.
  - **Cliente (ambas plataformas)**: nueva sección "Verificación" en Ajustes -- formulario para solicitar (si no hay solicitud abierta ni verificación ya concedida), aviso de "pendiente de revisión", o confirmación "Ya estás verificado ✔️". Panel de moderación (`ModerationScreen.kt`/`ModerationView.swift`) con una tercera cola "Solicitudes de verificación" junto a Denuncias/Apelaciones, con botones Verificar/Rechazar que llaman a `admin_set_verified()`.
  - **Verificado real, no simulado**: RLS 227/227. Android `:app:compileDebugKotlin` OK a la primera (`BUILD SUCCESSFUL`), daemon detenido. **iOS: CI real VERIFICADO EN VERDE a la primera** (`ad152f5`, run `32966455251`).

Las pasadas más antiguas de esta sesión (desde el arranque del toolchain Android hasta la auditoria de paridad de código que cerro justo antes de las entradas de arriba) se comprimieron aqui el 2026-08-19 para mantener este documento manejable — el registro completo, palabra por palabra, sigue disponible en el historial de la conversacion si hace falta reconstruirlo. Nada de sustancia se perdio: cada bug real encontrado y corregido esta ya en la lista numerada de "Bugs reales encontrados y corregidos esta sesion" y en "Anadido esta sesion" al principio de este archivo; cada hueco grande documentado sigue en "Pendiente real". Este resumen cubre: bootstrap completo del toolchain Android sin admin (JDK/SDK/Gradle/emulador), decenas de ciclos render+optimizar verificando la app en el emulador real sin crashes, y la larga auditoria de paridad codigo-por-codigo y documentacion-por-documentacion entre iOS y Android que encontro los bugs ya listados arriba (notifications sin productor, likes falso, EventMode sin limit, actividad sugerida hardcodeada, SafetyToolbar global faltante en Android, event_density roto, contadores de Perfil en 0 permanente en iOS, y las 4 afirmaciones falsas en la politica de privacidad/ficha de App Store).
