-- ============================================================================
-- SOCIAL — Avisos reales para mensajes de grupo, comparado con WhatsApp/
-- Messenger/Facebook: un mensaje nuevo en un grupo notifica a todo el
-- resto de miembros. `group_messages` (0057_group_chats.sql) no generaba
-- ningún aviso -- mismo patrón exacto que `notify_new_message` (1:1,
-- 0047_message_notify_mute.sql), pero a TODOS los demás miembros del
-- grupo en vez de a un único destinatario.
--
-- Hallazgo real de paso, encontrado auditando send-push/index.ts y
-- AvisosViewModel.kt/.swift al añadir este nuevo kind: 'comment',
-- 'comment_like' y 'reel_comment_like' YA estaban en
-- `notifications_kind_check` desde hace varias rondas, pero NUNCA se
-- añadieron a los switches de icono/título de ninguno de los tres sitios
-- (send-push real, y las dos listas de Avisos en pantalla) -- un push o
-- aviso real para esos tres tipos caía siempre en el "🔔"/"Notificación"
-- genérico, aunque la base de datos y la lógica de notificación en sí
-- funcionaran perfectamente. Corregido aquí de una vez junto con
-- 'group_message' (documentado en el propio código de cada plataforma,
-- esta migración solo toca SQL).
-- ============================================================================

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message'));

create or replace function private.notify_new_group_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  select
    gcm.user_id,
    new.sender_id,
    'group_message',
    jsonb_build_object('group_chat_id', new.group_chat_id, 'actor_id', new.sender_id)
  from public.group_chat_members gcm
  where gcm.group_chat_id = new.group_chat_id
    and gcm.user_id <> new.sender_id;
  return new;
end;
$$;

revoke execute on function private.notify_new_group_message() from public, anon, authenticated;

drop trigger if exists trg_notify_new_group_message on group_messages;
create trigger trg_notify_new_group_message
  after insert on group_messages
  for each row execute function private.notify_new_group_message();
