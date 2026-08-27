-- ============================================================================
-- SOCIAL — "Eliminar para mí" también en el chat de GRUPO, cierra el
-- alcance deliberado de 0118 (solo 1:1)
--
-- Mismo diseño exacto que 0118_delete_message_for_me.sql: `deleted_for`
-- (array de ids), sin política nueva -- `group_messages_update_pin`
-- (0089) ya deja a CUALQUIER miembro del grupo hacer un UPDATE de la
-- fila sin restricción de columna. La guardia real va en
-- `protect_group_message_identity` (última versión, 0089): cada quien
-- solo puede añadirse a sí mismo, nunca quitar a otro. Resuelto en el
-- CLIENTE (nunca en `group_messages_select`), mismo hallazgo real ya
-- aprendido en 0118: una condición de SELECT sobre la propia columna
-- que se está modificando rompe el UPDATE del mismo actor.
-- ============================================================================

alter table group_messages add column deleted_for uuid[] not null default '{}';

create or replace function private.protect_group_message_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
    if current_user <> 'postgres' then
        new.group_chat_id := old.group_chat_id;
        new.sender_id := old.sender_id;
        new.created_at := old.created_at;
    end if;
    if (
        new.body is distinct from old.body
        or new.media_url is distinct from old.media_url
        or new.audio_url is distinct from old.audio_url
        or new.edited_at is distinct from old.edited_at
    ) and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.media_url := old.media_url;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;
    if new.pinned_at is not null and new.pinned_by is distinct from v_uid and current_user <> 'postgres' then
        new.pinned_at := old.pinned_at;
        new.pinned_by := old.pinned_by;
    end if;

    -- Eliminar para mí (0120): cada quien solo puede añadirse a sí
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
