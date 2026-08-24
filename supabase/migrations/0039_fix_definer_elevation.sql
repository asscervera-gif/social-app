-- ============================================================================
-- SOCIAL — Arreglo real: admin_ban_user (0037) nunca funcionó en producción
--
-- Hallazgo real, encontrado al verificar contra el proyecto Supabase real
-- (no el simulador local PGlite): `auth.role()` en Supabase de verdad lee
-- `current_setting('request.jwt.claim.role')` — el rol del JWT del que
-- llama — y NO se ve afectado por `set_config('app.role', 'service_role',
-- true)` como asumía 0037 (esa variable de sesión `app.role` es una
-- convención inventada solo por el simulador local de pruebas, no algo
-- que Supabase real lea nunca). Resultado: `admin_ban_user()` llamaba a su
-- propio UPDATE seguro creyendo haberse "elevado" a service_role, pero
-- `protect_ban_columns` seguía viendo `auth.role() = 'authenticated'` y
-- revertía el baneo en silencio — la función parecía funcionar (no lanzaba
-- error) pero no baneaba a nadie de verdad.
--
-- Señal real verificada empíricamente contra el proyecto real: dentro de
-- una función `security definer` cuyo dueño es el rol `postgres` (todas las
-- funciones de este proyecto, creadas vía la conexión directa de
-- migraciones), `current_user` pasa a ser literalmente 'postgres' — sin
-- importar qué rol (authenticated/anon) llamó a la función. Ningún cliente
-- puede falsificar esto: no tiene privilegios para crear una función
-- propiedad de postgres. Es la señal real de "esta escritura viene de
-- dentro de una de nuestras funciones de confianza ya auditadas".
-- ============================================================================

create or replace function private.protect_ban_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.role() <> 'service_role' and current_user <> 'postgres' then
        if new.is_banned <> old.is_banned then
            new.is_banned := old.is_banned;
        end if;
        if new.banned_until is distinct from old.banned_until then
            new.banned_until := old.banned_until;
        end if;
        if new.ban_reason is distinct from old.ban_reason then
            new.ban_reason := old.ban_reason;
        end if;
    end if;
    return new;
end;
$$;

create or replace function admin_ban_user(
    p_target_id uuid,
    p_banned boolean,
    p_until timestamptz default null,
    p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller_is_admin boolean;
begin
    select is_admin into caller_is_admin from public.profiles where id = (select auth.uid());
    if caller_is_admin is not true then
        raise exception 'admin_ban_user: caller is not an admin';
    end if;

    -- Ya no hace falta el set_config('app.role', ...) de 0037 — no hacía
    -- nada real. La función ya escribe como current_user = 'postgres' por
    -- ser security definer, que es la señal que protect_ban_columns
    -- comprueba de verdad ahora.
    update public.profiles
    set is_banned = p_banned,
        banned_until = case when p_banned then p_until else null end,
        ban_reason = case when p_banned then p_reason else null end
    where id = p_target_id;
end;
$$;
