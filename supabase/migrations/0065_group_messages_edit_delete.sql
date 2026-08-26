-- ============================================================================
-- SOCIAL — Editar y borrar el propio mensaje en un chat de grupo real,
-- comparado con WhatsApp/Telegram/Messenger: el chat 1:1 ya deja editar
-- (0049_messages_edit.sql) y borrar (0022_messages_delete.sql) el propio
-- mensaje, pero `group_messages` (0057_group_chats.sql) nunca tuvo NINGUNA
-- política de UPDATE/DELETE -- un mensaje mal escrito en un grupo se
-- quedaba para siempre, sin forma de corregirlo ni borrarlo, ni siquiera
-- el propio remitente. "Borrar para todos" (no un borrado solo-para-mí),
-- mismo criterio simple que el chat 1:1. Sin ventana de tiempo límite para
-- editar, mismo alcance deliberado que 0049.
--
-- Diferencia real de riesgo frente al 1:1, y por qué SÍ hace falta un
-- trigger aquí aunque `group_messages` no tenga el mismo agujero exacto
-- que 0049 encontró en `messages` (`messages_update_read` ya daba a
-- CUALQUIER destinatario una política de UPDATE sobre la fila ajena,
-- combinada por Postgres con OR a nivel de fila con `messages_update_own`
-- -- `group_messages` no tiene ningún equivalente: "visto por" de grupo
-- vive en su propia tabla, `group_message_reads`, 0061, no en una columna
-- de `group_messages`, así que no hay ninguna otra política de UPDATE con
-- la que `group_messages_update_own` pueda combinarse). El riesgo aquí es
-- distinto: `with check (sender_id = auth.uid())` certifica que el NUEVO
-- sender_id sigue siendo el propio remitente, pero no dice nada sobre
-- `group_chat_id` -- sin más, el propio remitente podría "trasladar" su
-- propio mensaje ya enviado a un `group_chat_id` distinto (uno donde ni
-- siquiera es miembro, esquivando por completo la comprobación de
-- `private.is_group_member` que si protege el INSERT original). Mismo
-- patrón exacto ya usado esta sesión para `group_chat_members`
-- (`trg_protect_group_chat_member_identity`, 0064): RLS de UPDATE
-- necesariamente amplia a nivel de fila + trigger que revierte las
-- columnas que identifican dónde/de quién es la fila.
-- ============================================================================

alter table group_messages add column if not exists edited_at timestamptz;

create policy group_messages_update_own on group_messages
    for update
    using (sender_id = (select auth.uid()))
    with check (sender_id = (select auth.uid()));

create policy group_messages_delete_own on group_messages
    for delete
    using (sender_id = (select auth.uid()));

create or replace function private.protect_group_message_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if current_user <> 'postgres' then
        new.group_chat_id := old.group_chat_id;
        new.sender_id := old.sender_id;
        new.created_at := old.created_at;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_group_message_identity() from public, anon, authenticated;

drop trigger if exists trg_protect_group_message_identity on group_messages;
create trigger trg_protect_group_message_identity
    before update on group_messages
    for each row
    execute function private.protect_group_message_identity();
