# Notas de escalabilidad — SOCIAL a millones de usuarios simultáneos

Separar dos cosas que suelen confundirse: la parte de la app que **nunca
toca servidor** (proximidad UWB, peer-to-peer entre dos teléfonos) escala
sola, gratis, hasta el infinito — no hay servidor de por medio. Lo que sí
hay que dimensionar es todo lo que pasa por Supabase: backend, chat, IA,
feed. Ahí es donde "millones de usuarios simultáneos" tiene coste real.

## Lo que ya escala por diseño

- **UWB/Nearby/Multipeer**: cada medición de distancia ocurre directamente
  entre dos dispositivos, sin servidor. Un millón de usuarios usando SOCIAL
  a la vez en ciudades distintas no genera ni una sola petición extra al
  backend por esto — es la parte más escalable de toda la app, por
  construcción.
- **Edge Functions (`duel-ai`)**: al ser serverless, Supabase las escala
  automáticamente por invocación. El cuello de botella no es la función en
  sí, es la API de Anthropic detrás (rate limits de la cuenta) — por eso el
  límite de 20 llamadas/hora/usuario ya implementado no es solo
  anti-abuso, también protege el presupuesto a escala.

## Lo que SÍ hay que dimensionar (y cómo)

### 1. Conexiones a Postgres

Postgres tiene un límite duro de conexiones simultáneas (cientos, no
millones). Con millones de usuarios activos, la app debe pasar por
**pooling**, no conectar directo:

- Usar el connection pooler de Supabase (Supavisor, modo transaction) para
  todo el tráfico de la app — ya es el comportamiento por defecto del
  cliente `supabase-swift`/`supabase-kt` contra la URL pública del proyecto,
  pero hay que confirmarlo explícitamente en el dashboard antes de escalar.
- Nunca abrir conexiones Postgres directas desde el cliente (solo desde
  Edge Functions o servicios backend de confianza).

### 2. Supabase Realtime (chat, avisos, votos de compatibilidad)

Cada usuario con un chat abierto mantiene un WebSocket. Esto es lo primero
que se satura a escala:

- Un solo proyecto Supabase tiene un límite de conexiones Realtime
  concurrentes según el plan — en el plan Enterprise se negocia el techo,
  pero **hay que probarlo con carga real antes de asumir que "ya escala"**.
- Mitigación de diseño ya presente: los canales son por chat
  (`chat-{chatId}`) y por usuario (`notifications-{userId}`), no un canal
  global — evita que todo el tráfico pase por un único canal saturado.
- A partir de cierto volumen, la estrategia estándar es **sharding por
  región**: varios proyectos Supabase (uno por región geográfica: EU, US,
  LatAm...), con el cliente eligiendo el más cercano al hacer login. Esto
  no está implementado — es la primera pieza de infraestructura real que
  habría que construir antes de un lanzamiento masivo.

### 3. Row Level Security a escala

Las políticas RLS ya siguen las buenas prácticas de rendimiento
(`(select auth.uid())` en vez de `auth.uid()` sin envolver, funciones
`security definer` con índices en las columnas que consultan — ver
`security_checklist.md`). A escala, además:

- Vigilar con `EXPLAIN ANALYZE` las consultas más frecuentes (feed de Home,
  cuadrícula de Match) según crezcan las tablas `posts` y `profiles`.
- Considerar una tabla materializada o caché (Redis/Supabase Cache) para el
  feed de Home si el `order by created_at` sobre millones de filas se
  vuelve lento — no es necesario hoy, sí lo será con volumen real.

### 4. Storage y CDN (avatares, fotos, reels)

- Los avatares y medios deben servirse desde el Storage de Supabase (que ya
  usa un CDN) o desde un CDN dedicado (Cloudflare, CloudFront) — nunca
  desde la base de datos ni desde una Edge Function.
- Los reels/vídeos necesitan transcodificación adaptativa (HLS/DASH) a
  partir de cierto volumen — no está implementado, es trabajo de
  infraestructura de vídeo dedicada (fuera del alcance de este código base).

### 5. Notificaciones a escala (fan-out)

**Actualizado**: la recomendación de "mover la creación de notificaciones a
triggers de Postgres" ya está implementada para notificaciones 1-a-1
(`0006_notification_triggers.sql`: socials/follows/compat_requests/duels;
`0007_likes.sql`: likes) — antes ni siquiera existía ningún productor de
notificaciones, ver `LOOP_STATE.md`. Lo que sigue sin resolver es
específicamente el caso de "notificar a todos los asistentes de un evento
grande" (fan-out a muchos destinatarios de golpe, no un trigger por fila
insertada en otra tabla):

- Los triggers actuales insertan como máximo una notificación por fila
  insertada en `socials`/`follows`/`compat_requests`/`duels`/`likes` — eso
  ya no debe hacerse con inserts uno a uno desde el cliente, y no lo hace.
  Pendiente distinto: un evento que afecte a N asistentes a la vez (p. ej.
  "el evento va a cerrar en 10 minutos") sí necesitaría procesamiento por
  lotes (batch insert) en vez de N triggers individuales — no hay ningún
  caso de uso así implementado todavía en el producto, así que no hay nada
  que optimizar aún, pero quedará pendiente en cuanto se añada uno.
- Para push notifications reales (APNs/FCM), se necesita una cola
  (pgmq, o un servicio externo tipo SQS) entre el evento y el envío, para
  no bloquear la transacción que lo origina. Sigue sin implementar — los
  triggers actuales solo escriben en `notifications`, no envían push.

### 6. Rate limiting general

Ya implementado para `duel-ai` (`ai_usage`, 20/hora). A escala, extender el
mismo patrón a: envío de socials, compat_requests y reports — sin límite,
son los vectores de spam/abuso más baratos de explotar cuando hay millones
de cuentas.

## Lo que esto NO resuelve por sí solo

Nada de lo anterior sustituye una prueba de carga real. Antes de anunciar
"soporta millones de usuarios", hace falta:

1. Un test de carga sobre Supabase (k6, Artillery) simulando el patrón real
   de uso (chats abiertos, votos de compatibilidad, feed) a la concurrencia
   objetivo.
2. Confirmar con el equipo de Supabase el techo real de conexiones Realtime
   del plan contratado — es información que cambia y que solo ellos
   confirman con certeza.
3. Decidir la estrategia de sharding por región ANTES de tener usuarios en
   producción — migrar de un proyecto único a sharding con datos reales ya
   escritos es mucho más caro que diseñarlo desde el principio.
