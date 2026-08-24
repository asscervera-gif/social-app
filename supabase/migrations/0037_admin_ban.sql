-- ============================================================================
-- SOCIAL — Fase 10b: moderación real, segunda pieza (baneo)
--
-- Hallazgo real: 0036 dio a un admin la capacidad de LEER y marcar
-- reviewed/dismissed una denuncia, pero ninguna acción real de moderación
-- existía todavía — un admin podía leer que un usuario era denunciado 50
-- veces y no tenía ninguna forma de impedir que ese usuario siguiera usando
-- la app. Esto añade el baneo real: `profiles.is_banned` +
-- `profiles.banned_until` (baneo temporal o permanente si `banned_until`
-- es null), protegidos con el mismo patrón de trigger que `is_admin`
-- (0036) / `is_verified` (0029) — el cliente nunca puede autoconcederse ni
-- quitarse el baneo directamente vía UPDATE normal.
--
-- La vía real para banear es una función `admin_ban_user()` security
-- definer que comprueba `is_admin` del llamante ANTES de tocar la fila
-- ajena — no una política RLS de UPDATE abierta sobre `profiles` para
-- admins, que habría sido una superficie de ataque mucho mayor (un bug en
-- esa política podría haber dejado a un admin comprometido tocar
-- cualquier columna de cualquier perfil, no solo el baneo).
-- ============================================================================

alter table profiles add column is_banned boolean not null default false;
alter table profiles add column banned_until timestamptz;
alter table profiles add column ban_reason text;

create or replace function private.protect_ban_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.role() <> 'service_role' then
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

revoke execute on function private.protect_ban_columns() from public, anon, authenticated;

drop trigger if exists trg_protect_ban_columns on profiles;
create trigger trg_protect_ban_columns
    before update on profiles
    for each row
    execute function private.protect_ban_columns();

-- security definer: se ejecuta con los privilegios del propietario de la
-- función (que sí puede escribir is_banned pese al trigger de arriba,
-- porque corre en un contexto donde auth.role() = 'service_role' no se
-- cumple para el llamante pero la función en sí actualiza directamente sin
-- volver a pasar por el chequeo de rol del cliente) — la comprobación real
-- de autorización es el `is_admin` del CALLER, verificado explícitamente
-- dentro de la función antes de escribir nada.
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

    -- La misma auth.role() que lee el trigger protect_ban_columns está
    -- fijada al rol JWT del llamante (authenticated), no cambia por ser
    -- esta una función security definer — ni en este entorno de pruebas
    -- ni en Supabase real (el rol de PostgREST no cambia solo porque la
    -- función lo sea). Por eso el trigger seguiría revirtiendo este mismo
    -- UPDATE si no se eleva explícitamente aquí, DESPUÉS de haber
    -- verificado ya que quien llama es admin. set_config(..., true) es
    -- local a esta transacción: se deshace solo al terminar, no permanece
    -- para ninguna sentencia posterior de la sesión.
    perform set_config('app.role', 'service_role', true);

    update public.profiles
    set is_banned = p_banned,
        banned_until = case when p_banned then p_until else null end,
        ban_reason = case when p_banned then p_reason else null end
    where id = p_target_id;
end;
$$;

revoke execute on function admin_ban_user(uuid, boolean, timestamptz, text) from public, anon;
grant execute on function admin_ban_user(uuid, boolean, timestamptz, text) to authenticated;

-- Un baneo temporal cuyo `banned_until` ya pasó ya no debería contar como
-- baneo activo — esta vista es lo que consulta el cliente al arrancar
-- (equivalente a "¿me dejan entrar?"), en vez de mirar `is_banned` en
-- crudo, que no caduca solo.
create or replace view my_ban_status
with (security_invoker = true)
as
select
    id,
    is_banned and (banned_until is null or banned_until > now()) as is_currently_banned,
    banned_until,
    ban_reason
from profiles
where id = (select auth.uid());
