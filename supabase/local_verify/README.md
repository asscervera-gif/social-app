# Verificación local de las migraciones (sin Docker, sin Supabase real)

Descubrimiento real de esta sesión: aunque este entorno nunca ha podido
instalar Postgres nativo ni Docker (límite documentado desde el
principio en `LOOP_STATE.md`), **sí tiene Node**, y
[`@electric-sql/pglite`](https://www.npmjs.com/package/@electric-sql/pglite)
empaqueta un Postgres real (no un simulador) compilado a WASM. Esto
permite ejecutar las 35 migraciones de `supabase/migrations/` contra un
motor de base de datos de verdad, algo que hasta esta pasada nunca se
había hecho — todas las migraciones estaban "razonadas y revisadas con
cuidado", no verificadas de verdad.

## Qué NO reemplaza esto

PGlite es Postgres real, pero **no** es un proyecto Supabase real: no
trae el runtime completo de GoTrue/PostgREST/Storage/Realtime, así que
`run_migrations.mjs`/`test_triggers.mjs` rellenan a mano lo mínimo que
las migraciones necesitan (roles `anon`/`authenticated`/`service_role`,
`auth.users`, `auth.uid()`/`auth.role()` como funciones stub,
`storage.buckets`/`storage.objects`/`storage.foldername()`). Que las 35
migraciones se apliquen limpio aquí es una garantía real de que el SQL
es sintácticamente correcto y de que la lógica de los triggers hace lo
que dice — **no** es lo mismo que haberlo probado contra un proyecto
Supabase real con RLS aplicado de verdad por PostgREST, que sigue siendo
el paso pendiente documentado en `../DEPLOYMENT.md`.

## Uso

```
cd supabase/local_verify
npm install
npm run migrations   # aplica las 35 migraciones en orden, reporta cuáles fallan
npm run triggers     # además, inserta/actualiza filas reales y comprueba
                      # que los triggers de seguridad (is_verified,
                      # compatibility_score, post like_count/comment_count,
                      # event_attendees.social_count) hacen exactamente
                      # lo que deberían — no solo que compilan.
npm run rls          # el más fuerte de los tres: cambia de rol de verdad
                      # (SET ROLE authenticated + una fila auth.uid()
                      # distinta por prueba, con los mismos privilegios de
                      # tabla que un proyecto Supabase real concede fuera
                      # de las migraciones) y comprueba que las políticas
                      # RLS de bloqueo (mensajes, reacciones, votos de
                      # compatibilidad, solicitudes de %, aceptar un
                      # social) deniegan/permiten exactamente lo que
                      # deberían para un usuario real distinto — no el
                      # superusuario que bypasea RLS por defecto.
```

Última vez que se corrió (esta pasada): **35/35 migraciones OK**, **7/7
pruebas funcionales de triggers OK**, **17/17 pruebas de RLS con cambio
de rol real OK** — bloqueo (mensajes/reacciones/votos/solicitudes de %/
likes), visibilidad "solo socials" de posts y secciones de perfil (un
tercero sin relación no ve nada, el social aceptado real sí), el
ranking de Modo Evento no se puede falsear desde el propio INSERT, y la
cascada real de `delete-account` al borrar `auth.users`.

## Cuándo volver a correrlo

Cada vez que se añada una migración nueva o se toque un trigger de
seguridad existente — es rápido (segundos) y ahora es gratis tenerlo,
así que no hay razón para volver a confiar solo en la relectura manual.
