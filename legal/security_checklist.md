# Checklist de seguridad — SOCIAL

Una app que revela la distancia y dirección exacta de desconocidos tiene un
perfil de riesgo distinto al de una red social normal: el peor caso no es
"me roban datos", es "alguien usa la app para localizar y acosar a otra
persona físicamente". Este checklist prioriza eso primero, seguridad de
infraestructura después.

## 1. Riesgo específico de la función UWB (prioridad máxima)

- [x] **Nunca exponer la distancia/ángulo UWB fuera del dispositivo.** Ya
  cumplido por diseño: `SocialProximity.swift` mantiene las mediciones en
  memoria local, no las envía a Supabase. Verificar que ningún cambio futuro
  rompa esto — sería el fallo más grave posible de la app.
- [x] **Rate-limit al emparejamiento Multipeer.** Resuelto:
  `shouldInvite(_:)` limita a 5 invitaciones por `MCPeerID` cada 60s en
  `browser(_:foundPeer:withDiscoveryInfo:)`.
- [x] **El modo invisible debe ser real, no cosmético.** Resuelto:
  `SocialProximity.setDiscoverable(_:)` detiene `MCNearbyServiceAdvertiser`,
  y `SocialCameraView.invisibleToggle` lo llama junto con
  `SafetyManager.setInvisible` en el mismo toque.
- [x] **Filtrado de bloqueados a nivel de motor, no solo de UI.** Resuelto:
  `SocialProximity.blockedPeerIDs` se sincroniza desde la tabla `blocks` en
  `SocialCameraView.loadBlockedPeers()` y se comprueba en
  `startNISession` antes de arrancar cualquier medición.
- [ ] **Verificación de edad estricta.** Sin ella, la combinación
  "localización precisa + desconocidos + menores" es el escenario de riesgo
  más grave legal y éticamente. Bloquear <18 en el registro, sin excepción.
  Sigue pendiente — falta el flujo de registro completo (fuera de las 7
  fases del prompt original).
- [x] **Suavizado y detección de datos obsoletos.** No es un riesgo de
  seguridad pero sí de credibilidad del producto — ver
  `uwb_reliability_notes.md`. Resuelto con el filtro de paso bajo y el
  watchdog de 1s en `SocialProximity.swift`.

## 2. Row Level Security (Supabase) — ya implementado, verificar en cada cambio

- [ ] Toda tabla nueva debe llevar `alter table ... enable row level
  security;` en el mismo commit que la crea — nunca después.
- [ ] Las 4 reglas de negocio (`0002_rls.sql`) tienen test manual antes de
  cada release: crear dos usuarios de prueba, confirmar que A no puede leer
  secciones privadas ni posts `is_social_only` de B sin un social aceptado.
- [ ] Revisar con `supabase db lint` (o el linter del dashboard) que ninguna
  política nueva omite `(select auth.uid())` y cae en el antipatrón de
  llamar la función por fila.

## 3. Edge Functions y secretos

- [ ] `ANTHROPIC_API_KEY` vive solo como secreto de Supabase — confirmado en
  `duel-ai/index.ts`. Nunca debe aparecer en un commit, log, o respuesta de
  error.
- [x] **Rate limiting en `duel-ai`.** Resuelto: `checkAndRecordUsage` limita
  a 20 llamadas/hora por usuario autenticado, usando la tabla `ai_usage`
  (`0004_ai_usage.sql`) y fallando cerrado si no se puede verificar el
  límite.
- [ ] Validar el `action` y los payloads de entrada antes de construir el
  prompt — ya lo hace `buildPrompt`, pero cualquier campo nuevo debe
  validarse igual (nunca interpolar texto de usuario sin control en un
  prompt que luego se ejecuta con permisos de servicio).

## 4. Abuso y moderación

- [ ] `reports` (denuncias) necesita un proceso humano de revisión — el
  código cliente solo inserta filas; falta el panel/flujo de moderación
  (fuera del alcance de la app cliente, pero bloqueante para producción).
- [ ] Umbral automático: si un usuario acumula N `reports` con `status =
  'open'` en poco tiempo, marcarlo para revisión prioritaria o suspensión
  automática temporal (implementar como Edge Function programada).
- [x] **`blocks` filtrado también en `SocialProximity`.** Resuelto: ambas
  plataformas cargan `blocks` en `SocialCameraScreen.kt`/`SocialCameraView.swift`
  (`loadBlockedPeers()`) y lo comprueban dentro del propio motor UWB antes
  de mostrar un marcador — `SocialProximity.kt:343` y
  `SocialProximity.swift:229` descartan explícitamente cualquier peer
  bloqueado, no solo a nivel de UI. Este ítem estaba desactualizado: la
  auditoría de este `/loop` confirmó que ya estaba implementado y lo
  corrigió a `[x]`.

## 5. Cuentas y autenticación

- [ ] Usar Supabase Auth con verificación de email/teléfono obligatoria
  antes de poder usar la cámara de descubrimiento (no solo para registrarse).
- [ ] Considerar exigir verificación de cuenta (selfie vs. avatar, Fase 7)
  antes de permitir enviar el primer "social" — reduce perfiles falsos,
  que es el vector de abuso más común en apps de encuentro físico.

## 6. Infraestructura / servidores

- [ ] **Backups automáticos** de la base de datos Supabase (point-in-time
  recovery activado en el plan de pago antes de tener usuarios reales).
- [ ] **Migraciones versionadas**: seguir aplicando cambios solo vía
  `supabase/migrations/*.sql` numerados, nunca editando el esquema a mano
  desde el dashboard en producción.
- [ ] **Monitorización**: activar las alertas de Supabase (uso de DB, errores
  de Edge Functions) antes del lanzamiento — sin esto, un bug de RLS o un
  abuso de la API de IA puede pasar días sin detectarse.
- [ ] **Entornos separados**: proyecto Supabase de `staging` distinto al de
  `production`, con `Config.plist` distinto por esquema de build en Xcode.

## 7. Cadena de suministro (dependencias)

- [ ] Fijar versión exacta de `supabase-swift` en `project.yml` antes de
  producción (`exactVersion` en vez de `from`), para que un cambio de la
  librería no rompa builds de forma inesperada.
- [ ] Revisar el `Package.resolved` en cada PR — un cambio de dependencia
  transitiva no declarado es la forma más común de comprometer una app iOS.
