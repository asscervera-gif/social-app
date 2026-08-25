-- ============================================================================
-- SOCIAL — notificación real de mensaje nuevo + silenciar una conversación
--
-- Hallazgo real, el hueco de mensajería más grande encontrado esta sesión,
-- comparado con WhatsApp/Instagram/Messenger/Twitter DMs: NINGÚN mensaje
-- nuevo genera nunca un aviso. 0006_notification_triggers.sql solo cubre
-- social/follow/fight/like/compat_request -- `messages` nunca dispara nada
-- hacia `notifications`, así que NotificationsBadgeViewModel.swift/
-- LocalNotifier.kt (que sí escuchan esa tabla, ya con push real -- ver
-- 0041_notify_push_trigger.sql) jamás se enteran de un mensaje nuevo. La
-- única vía "en vivo" que existe hoy es el canal Realtime propio de
-- ChatViewModel -- si el destinatario no tiene esa pantalla abierta en
-- ese instante, un mensaje nuevo es completamente invisible: sin badge,
-- sin notificación local, sin push real. Solo se descubre por casualidad,
-- abriendo "Tus chats".
--
-- Ahora que un mensaje sí puede generar un aviso real, hace falta poder
-- silenciar una conversación sin salir de ella ni bloquear a nadie --
-- mismo concepto que WhatsApp/Instagram/Messenger. Dos columnas booleanas
-- por participante, protegidas con el mismo trigger `current_user <>
-- 'postgres'` ya usado en `protect_chat_hidden_flags` (0044): cada quien
-- solo silencia SU PROPIA copia, nunca la de la otra persona. A
-- diferencia de `hidden_by_*`, silenciado NO se deshace solo al llegar un
-- mensaje nuevo -- deshacerlo automáticamente contradiría el propósito
-- exacto de la función.
--
-- Aviso de honestidad / límite conocido: el trigger no sabe si el
-- destinatario tiene la conversación abierta en pantalla en ese instante
-- (esa información solo vive en el canal Presence de Realtime,
-- cliente-a-cliente, no en ninguna tabla consultable desde un trigger de
-- servidor) -- WhatsApp sí suprime la notificación de la conversación que
-- tienes abierta; aquí no, mismo criterio de simplicidad que el resto de
-- tipos de aviso ya existentes (un "follow" tampoco se suprime si estás
-- mirando la pantalla de Avisos). Mitigado en parte: ChatViewModel marca
-- como leídos los avisos de tipo "message" de ESE chat en cuanto se abre
-- (ver más abajo / ChatViewModel.kt), así no se acumulan avisos ya vistos
-- en el propio chat.
-- ============================================================================

alter table chats add column muted_by_a boolean not null default false;
alter table chats add column muted_by_b boolean not null default false;

create or replace function private.protect_chat_muted_flags()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.muted_by_a <> old.muted_by_a and (select auth.uid()) <> old.user_a_id and current_user <> 'postgres' then
        new.muted_by_a := old.muted_by_a;
    end if;
    if new.muted_by_b <> old.muted_by_b and (select auth.uid()) <> old.user_b_id and current_user <> 'postgres' then
        new.muted_by_b := old.muted_by_b;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_chat_muted_flags() from public, anon, authenticated;

drop trigger if exists trg_protect_chat_muted_flags on chats;
create trigger trg_protect_chat_muted_flags
    before update on chats
    for each row
    execute function private.protect_chat_muted_flags();

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message'));

create or replace function private.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_a uuid;
    v_user_b uuid;
    v_muted_a boolean;
    v_muted_b boolean;
    v_recipient uuid;
begin
    select user_a_id, user_b_id, muted_by_a, muted_by_b
      into v_user_a, v_user_b, v_muted_a, v_muted_b
      from public.chats where id = new.chat_id;

    if not found then
        return new;
    end if;

    if new.sender_id = v_user_a then
        v_recipient := v_user_b;
        if v_muted_b then
            return new;
        end if;
    else
        v_recipient := v_user_a;
        if v_muted_a then
            return new;
        end if;
    end if;

    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
        v_recipient,
        new.sender_id,
        'message',
        jsonb_build_object('chat_id', new.chat_id, 'actor_id', new.sender_id)
    );
    return new;
end;
$$;

revoke execute on function private.notify_new_message() from public, anon, authenticated;

drop trigger if exists trg_notify_new_message on messages;
create trigger trg_notify_new_message
    after insert on messages
    for each row
    execute function private.notify_new_message();
