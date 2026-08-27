-- ============================================================================
-- SOCIAL — "Eliminar para mí" real, comparado con WhatsApp
--
-- `deleteMessage()` (0022_messages_delete.sql) siempre fue un DELETE real
-- -- borra el mensaje para las DOS personas del chat. WhatsApp distingue
-- "Eliminar para mí" (solo desaparece de tu copia, la otra persona lo
-- sigue viendo con normalidad) de "Eliminar para todos" -- SOCIAL solo
-- tenía la segunda opción.
--
-- Diseño: `messages.deleted_for` (array de ids reales), sin política
-- nueva -- `messages_update_pin` (0089) ya deja a CUALQUIER participante
-- del chat hacer un UPDATE de la fila sin restricción de columna, mismo
-- patrón real ya usado para pinned_at/view_once. La guardia real va en
-- `protect_message_columns` (última versión, 0117): cada quien solo
-- puede AÑADIRSE a sí mismo al array, nunca quitar a otro ni añadir a
-- un tercero.
--
-- Hallazgo real encontrado ejecutando el test de esta misma migración
-- (no simulado): la primera versión también extendía `messages_select`
-- para ocultar la fila a quien se auto-excluyó (`and not (auth.uid() =
-- any(deleted_for))`) -- reproducido de forma aislada que esto rompía
-- el UPDATE real del propio remitente con "new row violates row-level
-- security policy", porque el nuevo valor de `deleted_for` deja de
-- satisfacer esa misma condición de SELECT para quien acaba de
-- añadirse. Mismo criterio ya aplicado a `muted_feed_keywords` (0116,
-- preferencia personal de "ocultar de MI vista", nunca una condición de
-- seguridad real): resuelto en el CLIENTE, nunca en RLS -- cualquiera
-- de los dos participantes sigue pudiendo LEER la fila completa (para
-- que el remitente pueda deshacer su propio "eliminar para mí" si algún
-- día se construye esa opción), y el cliente decide qué no pintar.
-- ============================================================================

alter table messages add column deleted_for uuid[] not null default '{}';

create or replace function private.protect_message_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_is_view_once_consumption boolean;
  v_uid uuid := (select auth.uid());
begin
    v_is_view_once_consumption := old.view_once
        and old.opened_at is null
        and new.opened_at is not null
        and (select auth.uid()) <> old.sender_id;

    if (
        new.body is distinct from old.body
        or new.audio_url is distinct from old.audio_url
        or new.edited_at is distinct from old.edited_at
    ) and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;

    if v_is_view_once_consumption then
        new.media_url := null;
    elsif new.media_url is distinct from old.media_url
        and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.media_url := old.media_url;
    end if;

    if new.read_at is distinct from old.read_at
        and (select auth.uid()) = old.sender_id and current_user <> 'postgres' then
        new.read_at := old.read_at;
    end if;

    if new.delivered_at is distinct from old.delivered_at
        and (select auth.uid()) = old.sender_id and current_user <> 'postgres' then
        new.delivered_at := old.delivered_at;
    end if;

    if new.pinned_at is not null and new.pinned_by is distinct from (select auth.uid()) and current_user <> 'postgres' then
        new.pinned_at := old.pinned_at;
        new.pinned_by := old.pinned_by;
    end if;

    if new.view_once is distinct from old.view_once
        and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.view_once := old.view_once;
    end if;

    if new.opened_at is distinct from old.opened_at
        and not v_is_view_once_consumption
        and current_user <> 'postgres' then
        new.opened_at := old.opened_at;
    end if;

    if new.disappear_at is distinct from old.disappear_at and current_user <> 'postgres' then
        new.disappear_at := old.disappear_at;
    end if;

    -- Eliminar para mí (0118): cada quien solo puede añadirse a sí
    -- mismo -- nunca quitar a otro del array ni añadir a un tercero.
    if new.deleted_for is distinct from old.deleted_for and current_user <> 'postgres' then
        if not (old.deleted_for <@ new.deleted_for)
           or not (new.deleted_for <@ (old.deleted_for || v_uid))
        then
            new.deleted_for := old.deleted_for;
        end if;
    end if;

    return new;
end;
$$;
