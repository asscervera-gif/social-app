-- ============================================================================
-- SOCIAL — editar un mensaje ya enviado
--
-- Hallazgo real, comparado con WhatsApp/Telegram/Messenger: un mensaje mal
-- escrito solo se podía borrar entero (0022_messages_delete.sql), nunca
-- corregir -- perdiendo el mensaje completo (y cualquier reacción/lectura
-- ya asociada) por una errata. `messages` no tenía NINGUNA política de
-- UPDATE que dejara al remitente tocar su propio `body`:
-- `messages_update_read` (0017) es justo lo contrario -- solo deja al
-- DESTINATARIO marcar `read_at`, nunca al remitente.
--
-- `edited_at` (nullable): mismo criterio visual que "editado" en
-- WhatsApp/Telegram -- si no es null, el cliente muestra la etiqueta.
--
-- Hallazgo de seguridad real, encontrado ESCRIBIENDO el test de esta
-- misma migración (no en producción, pero real igualmente): RLS en
-- Postgres combina varias políticas permisivas del mismo comando con OR
-- A NIVEL DE FILA, no de columna. `messages_update_read` (0017) ya
-- permitía a CUALQUIER destinatario (no remitente, miembro del chat)
-- hacer un UPDATE sobre la fila del mensaje ajeno -- su USING/WITH CHECK
-- solo comprueba `sender_id <> auth.uid()` y pertenencia al chat, sin
-- restringir NUNCA qué columnas se tocan. Eso significa que, desde 0017,
-- el destinatario podía en teoría reescribir `body`/`media_url`/
-- `audio_url` del mensaje del remitente con una sola sentencia UPDATE que
-- de paso tocara `read_at` -- suplantando el contenido del mensaje de
-- otra persona. Nunca se probó porque ningún test anterior intentaba
-- tocar `body` como no-remitente. Cerrado aquí con el mismo patrón ya
-- usado en `protect_chat_hidden_flags`/`protect_chat_muted_flags`
-- (trigger `current_user <> 'postgres'`, no `security definer`): revierte
-- `body`/`media_url`/`audio_url`/`edited_at` si quien edita no es el
-- remitente real, y revierte `read_at` si quien lo toca SÍ es el
-- remitente (ni siquiera debe poder mentirse a sí mismo sobre si su
-- propio mensaje fue leído, por consistencia, aunque el impacto de eso
-- solo sea cosmético).
--
-- Alcance deliberado, no una promesa de más: sin ventana de tiempo límite
-- para editar (WhatsApp sí tiene una, ~15 min) -- se mantiene simple por
-- ahora, editar siempre permitido mientras el mensaje exista.
-- ============================================================================

alter table messages add column edited_at timestamptz;

create policy messages_update_own on messages
    for update
    using (sender_id = (select auth.uid()))
    with check (sender_id = (select auth.uid()));

create or replace function private.protect_message_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if (
        new.body is distinct from old.body
        or new.media_url is distinct from old.media_url
        or new.audio_url is distinct from old.audio_url
        or new.edited_at is distinct from old.edited_at
    ) and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.media_url := old.media_url;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;
    if new.read_at is distinct from old.read_at
        and (select auth.uid()) = old.sender_id and current_user <> 'postgres' then
        new.read_at := old.read_at;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_message_columns() from public, anon, authenticated;

drop trigger if exists trg_protect_message_columns on messages;
create trigger trg_protect_message_columns
    before update on messages
    for each row
    execute function private.protect_message_columns();
