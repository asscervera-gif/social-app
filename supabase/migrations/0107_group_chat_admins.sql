-- ============================================================================
-- SOCIAL — Administradores reales de un chat de grupo, comparado con
-- WhatsApp/Telegram/Messenger
--
-- Las tres apps de referencia dejan a quien creó un grupo ascender a
-- OTRAS personas a administrador -- si no lo hiciera nunca, el grupo se
-- queda sin nadie que pueda moderar en cuanto quien lo creó deja de
-- estar disponible. Confirmado en el propio código: `group_chat_members`
-- (0057) no tenía ningún concepto de rol -- `group_chats.created_by` es
-- el ÚNICO real con privilegios (renombrar/cambiar foto/expulsar,
-- 0057/0063/0066), sin ninguna forma real de delegar ni una sola de esas
-- capacidades a nadie más.
--
-- Diseño real: `is_admin` en `group_chat_members` (una fila = una
-- persona en un grupo, mismo criterio ya usado para `muted`/`hidden`).
-- El creador real se marca admin de un tirón al crearse el grupo (mismo
-- trigger real que ya lo añade como miembro, 0057). Mismo patrón real
-- que `private.is_group_member` (0057) para evitar la recursión real de
-- RLS ya documentada ahí (una política de `group_chat_members` que
-- consultara `group_chat_members` de nuevo con un `exists` normal):
-- `private.is_group_admin`, `security definer`, nunca llamable
-- directamente por el cliente.
--
-- Hallazgo real de seguridad, aprendido de 0049/0089/0093 (no repetido,
-- evitado a propósito): `group_chat_members_update_own` (0064) ya deja a
-- CUALQUIER miembro hacer un UPDATE sobre su propia fila sin restricción
-- de columnas -- sin guardia, cualquiera podría ascenderse a sí mismo
-- con un UPDATE que de paso tocara `is_admin`. Cerrado extendiendo
-- `protect_group_chat_member_identity` (0064), la única guardia real de
-- columnas que ya existe para esta tabla: solo un admin real ya
-- existente puede cambiar `is_admin` (de cualquier fila, para ascender o
-- descender a otro).
--
-- SEGUNDO hallazgo real de seguridad, este ya encontrado ejecutando el
-- test ya existente de "marked_unread" (0088) con esta misma migración a
-- medio escribir: `group_chat_members_update_admin` (más abajo), al no
-- tener restricción de columna, dejaba a un admin real (incluido el
-- propio creador) tocar de paso `muted`/`hidden`/`pinned`/`muted_until`/
-- `marked_unread`/`last_read_at` -- preferencias PERSONALES que ni
-- siquiera el creador real podía tocar antes de esta ronda. Cerrado
-- extendiendo la misma guardia: esas columnas siguen siendo solo de su
-- propio dueño real, admin o no.
--
-- Alcance real de esta ronda: ascender/descender admins, y expulsar
-- miembros ya extendido a cualquier admin real (antes solo el creador,
-- 0066) -- renombrar el grupo/cambiar la foto siguen siendo solo del
-- creador real (`group_chats.created_by`), sin ampliar a admins todavía;
-- hueco real aparte, documentado en LOOP_STATE.md.
-- ============================================================================

alter table group_chat_members add column is_admin boolean not null default false;

create or replace function private.add_group_creator_as_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.group_chat_members (group_chat_id, user_id, is_admin) values (new.id, new.created_by, true);
  return new;
end;
$$;

create or replace function private.is_group_admin(p_group_chat_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.group_chat_members
    where group_chat_id = p_group_chat_id and user_id = p_user_id and is_admin = true
  );
$$;

revoke execute on function private.is_group_admin(uuid, uuid) from public, anon, authenticated;
grant execute on function private.is_group_admin(uuid, uuid) to authenticated, service_role;

-- Un admin real (creador o ascendido) puede tocar CUALQUIER fila del
-- mismo grupo -- la propia guardia de más abajo decide de verdad qué
-- columna puede cambiar (aquí, solo is_admin: la política por sí sola
-- no distingue columnas, mismo criterio ya documentado en 0049/0064).
create policy group_chat_members_update_admin on group_chat_members
    for update
    using (private.is_group_admin(group_chat_members.group_chat_id, (select auth.uid())))
    with check (private.is_group_admin(group_chat_members.group_chat_id, (select auth.uid())));

create or replace function private.protect_group_chat_member_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if current_user <> 'postgres' then
        new.group_chat_id := old.group_chat_id;
        new.user_id := old.user_id;
        new.joined_at := old.joined_at;
    end if;

    -- Administradores reales de grupo (0107_group_chat_admins.sql):
    -- `group_chat_members_update_admin` (más abajo) deja a un admin
    -- real tocar la fila ENTERA de cualquier persona, sin restricción
    -- de columna (mismo criterio real ya usado en
    -- `group_chat_members_update_own`) -- sin esta guardia, un admin
    -- podría también silenciar/ocultar/fijar/marcar como no leída la
    -- preferencia PERSONAL de otra persona, algo que ni siquiera el
    -- creador real podía hacer antes de esta migración. Hallazgo real,
    -- encontrado ejecutando el test ya existente de "marked_unread"
    -- (0088): estas columnas siguen siendo solo de su propio dueño
    -- real, para cualquiera (admin o no) que no sea él.
    if (
        new.muted is distinct from old.muted
        or new.hidden is distinct from old.hidden
        or new.pinned is distinct from old.pinned
        or new.muted_until is distinct from old.muted_until
        or new.marked_unread is distinct from old.marked_unread
        or new.last_read_at is distinct from old.last_read_at
    ) and (select auth.uid()) <> old.user_id and current_user <> 'postgres' then
        new.muted := old.muted;
        new.hidden := old.hidden;
        new.pinned := old.pinned;
        new.muted_until := old.muted_until;
        new.marked_unread := old.marked_unread;
        new.last_read_at := old.last_read_at;
    end if;

    -- is_admin: solo un admin real ya existente puede tocarlo (de
    -- cualquier fila, para ascender/descender a otro) -- sin esto,
    -- group_chat_members_update_own (0064) dejaría a CUALQUIER miembro
    -- ascenderse a sí mismo (mismo riesgo real de "varias políticas
    -- permisivas se combinan con OR a nivel de fila" ya documentado
    -- varias veces esta sesión).
    if new.is_admin is distinct from old.is_admin
        and not private.is_group_admin(old.group_chat_id, (select auth.uid()))
        and current_user <> 'postgres' then
        new.is_admin := old.is_admin;
    end if;

    return new;
end;
$$;

-- Expulsar a un miembro real, comparado con WhatsApp/Telegram/Messenger
-- -- extendido de "solo el creador" (0066) a "cualquier admin real".
create policy group_chat_members_delete_by_admin on group_chat_members
    for delete
    using (private.is_group_admin(group_chat_members.group_chat_id, (select auth.uid())));
