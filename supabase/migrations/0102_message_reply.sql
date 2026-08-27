-- ============================================================================
-- SOCIAL — Responder a un mensaje concreto (cita), comparado con
-- WhatsApp/Telegram/iMessage/Instagram DM
--
-- Las cuatro apps de referencia dejan "deslizar para responder" a un
-- mensaje concreto de la conversación, mostrando una vista previa citada
-- encima del mensaje nuevo -- distinto de "Reenviar"
-- (0072_message_forward.sql: manda una COPIA a OTRO chat) y de "Fijar"
-- (0081_pin_chats.sql: sin ninguna relación entre mensajes): aquí el
-- mensaje nuevo queda enlazado de verdad al mensaje concreto que cita,
-- dentro de la MISMA conversación. Confirmado en el propio código:
-- `messages`/`group_messages` no tenían ninguna columna ni concepto de
-- citar otro mensaje.
--
-- Diseño real: `reply_to_message_id`, referencia -- no copia -- al
-- mensaje real citado, `on delete set null` (si el mensaje citado se
-- borra después, la respuesta se queda sin la vista previa, igual que
-- WhatsApp/Telegram real: la cita desaparece, el mensaje que la mandó
-- sigue existiendo). Un trigger real en INSERT (nunca en UPDATE, para no
-- interferir con el propio `on delete set null` -- que Postgres aplica
-- como un UPDATE interno) impide citar un mensaje de OTRA conversación,
-- ni por error de cliente ni por un intento real: mismo criterio ya
-- aplicado esta sesión a protect_call_identity/
-- protect_group_message_identity.
-- ============================================================================

alter table messages add column reply_to_message_id uuid references messages(id) on delete set null;
alter table group_messages add column reply_to_message_id uuid references group_messages(id) on delete set null;

create or replace function private.check_reply_same_chat()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.reply_to_message_id is not null and not exists (
    select 1 from public.messages
    where id = new.reply_to_message_id and chat_id = new.chat_id
  ) then
    raise exception 'reply_to_message_id debe pertenecer al mismo chat';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_reply_same_chat on messages;
create trigger trg_check_reply_same_chat
  before insert on messages
  for each row execute function private.check_reply_same_chat();

create or replace function private.check_group_reply_same_chat()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.reply_to_message_id is not null and not exists (
    select 1 from public.group_messages
    where id = new.reply_to_message_id and group_chat_id = new.group_chat_id
  ) then
    raise exception 'reply_to_message_id debe pertenecer al mismo grupo';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_group_reply_same_chat on group_messages;
create trigger trg_check_group_reply_same_chat
  before insert on group_messages
  for each row execute function private.check_group_reply_same_chat();
