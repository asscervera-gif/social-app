# Desplegar SOCIAL contra un proyecto Supabase real

Este documento no existía — con 36 migraciones y 4 Edge Functions
acumuladas a lo largo de la sesión, no había ninguna guía de qué aplicar,
en qué orden, ni qué secretos configurar. Todo el desarrollo hasta ahora
ha corrido contra credenciales placeholder (`local.properties`/
`Config.plist`); esto documenta los pasos reales para conectar un
proyecto Supabase de verdad, honestamente, sin fingir que ya se ha hecho.

## 1. Crear el proyecto

En [supabase.com](https://supabase.com), crear un proyecto nuevo. Guardar:
- **Project URL** (`https://xxxx.supabase.co`)
- **anon public key**
- **service_role key** (nunca va en el cliente — solo la usan las Edge
  Functions, y Supabase ya la inyecta automáticamente en su entorno)

## 1.5. Verificar las migraciones ANTES de tocar un proyecto real

Antes de aplicar nada contra Supabase, se puede (y se debería) verificar
que las 36 migraciones son válidas y que los triggers de seguridad hacen
lo que dicen — de verdad, contra un Postgres real, no solo por lectura:

```
cd supabase/local_verify
npm install
npm run migrations   # las 36 migraciones, en orden, contra Postgres real (PGlite/WASM)
npm run triggers     # además, prueba en vivo is_verified/compatibility_score/
                      # like_count/social_count con inserts y updates reales
npm run rls          # el más fuerte: cambia de rol de verdad (SET ROLE
                      # authenticated) y comprueba que las políticas RLS de
                      # bloqueo deniegan/permiten lo correcto para un
                      # usuario real, no el superusuario que bypasea RLS
```

Ver `supabase/local_verify/README.md` para el detalle de qué sí y qué no
sustituye esto (no es un proyecto Supabase completo, pero sí es Postgres
de verdad).

## 2. Aplicar las migraciones

Todas las migraciones en `supabase/migrations/` están numeradas
(`0001_schema.sql` → `0036_admin_moderation.sql` a fecha de este
documento) y deben aplicarse en ese orden — cada una asume que las
anteriores ya corrieron (columnas, funciones y tablas que usan sin
volver a crearlas).

```
supabase link --project-ref <tu-project-ref>
supabase db push
```

`supabase db push` aplica las migraciones pendientes en orden numérico
automáticamente. Si se prefiere aplicarlas a mano (por ejemplo, para
revisarlas antes de un proyecto de producción), pegar cada archivo en el
SQL Editor del dashboard, en el mismo orden numérico.

**Corrección real (esta pasada, ampliada)**: aunque este entorno nunca ha
podido instalar Postgres nativo, sí se han ejecutado las 36 migraciones
contra Postgres real vía `supabase/local_verify/` (ver paso 1.5) —
36/36 aplican limpio, los triggers de seguridad se probaron con
inserts/updates reales, y las políticas RLS de bloqueo se probaron con
un cambio de rol real (`SET ROLE authenticated`, no el superusuario que
bypasea RLS) simulando dos usuarios distintos. Lo único que sigue sin
probarse aquí es contra un proyecto Supabase real completo (PostgREST
sirviendo la API HTTP de verdad, GoTrue emitiendo JWTs reales,
Storage/Realtime reales) — esa primera vez sigue siendo responsabilidad
de quien despliegue, idealmente contra un proyecto de *staging* antes
que producción.

## 3. Configurar el secreto de Anthropic

Tres Edge Functions (`duel-ai`, `activity-ai`, `icebreaker-ai`) llaman a
la API de Anthropic y comparten el mismo secreto:

```
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
```

`SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` NO hace falta configurarlos
a mano — Supabase los inyecta automáticamente en el entorno de cualquier
Edge Function del propio proyecto.

## 4. Desplegar las Edge Functions

```
supabase functions deploy duel-ai
supabase functions deploy activity-ai
supabase functions deploy icebreaker-ai
supabase functions deploy delete-account
```

`delete-account` no necesita `ANTHROPIC_API_KEY` (borra la cuenta vía
`service_role`, sin IA de por medio) pero sí necesita estar desplegada
para que `AccountManager.kt`/`.swift` funcione — sin ella, borrar la
cuenta desde Ajustes fallaría en producción aunque el código cliente esté
completo.

## 5. Actualizar las credenciales del cliente

**Android** (`Android/local.properties`, nunca se sube a git — cada
desarrollador/entorno tiene el suyo):
```
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_ANON_KEY=<anon-public-key-real>
```

**iOS** (`Social/Backend/Config.plist` — copiar desde
`Config.example.plist` si no existe todavía, tampoco se sube a git):
```xml
<key>SUPABASE_URL</key>
<string>https://xxxx.supabase.co</string>
<key>SUPABASE_ANON_KEY</key>
<string>anon-public-key-real</string>
```

## 6. Verificar el registro real

Por defecto, un proyecto Supabase nuevo exige confirmación de email al
registrarse — `AuthViewModel.kt/.swift.signUp()` ya maneja este caso
(mensaje "revisa tu correo" en vez de fallar en silencio), pero conviene
confirmar en **Authentication → Settings** del dashboard si se quiere ese
comportamiento o desactivarlo para pruebas internas.

## 7. Lo que sigue sin poder hacerse sin un humano

Ninguno de estos pasos los puede completar un agente de código, incluso
después de que el proyecto Supabase esté conectado y funcionando:
- Compilar y firmar la app iOS (requiere Xcode en un Mac real).
- Crear las cuentas de desarrollador de Apple/Google y subir los binarios
  (ver `legal/app_store_submission_checklist.md`).
- Verificación de edad/identidad real (KYC) — sigue siendo autodeclaración.
- Probar el motor UWB en dispositivos físicos reales, no en un emulador.
