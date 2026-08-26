-- ============================================================================
-- SOCIAL — @menciones reales dentro de un chat de GRUPO, comparado con
-- WhatsApp/Messenger/Telegram
--
-- 0074_mentions.sql dejó fuera a propósito "chats 1:1/de grupo" -- pero esa
-- decisión comparaba solo contra Instagram/Twitter/TikTok, donde mencionar
-- es sobre todo "enlazar un perfil en una superficie PÚBLICA". Comparado
-- ahora contra WhatsApp/Messenger/Telegram (grupos reales, no 1:1), sí hay
-- un hueco real: escribir "@usuario" en un grupo avisa a esa persona en
-- concreto -- y, a diferencia de un mensaje normal, ese aviso SALTA el
-- silencio del grupo (`group_chat_members.muted`/`muted_until`,
-- 0064/0082) -- confirmado leyendo private.notify_new_group_message()
-- (0082_mute_until.sql): la notificación normal de "group_message" SÍ se
-- suprime si el destinatario tiene el grupo silenciado; @mencionar a
-- alguien en un grupo silenciado que igual le avisa es precisamente la
-- diferencia real que ofrecen esas tres apps frente a un mensaje cualquiera.
--
-- Alcance deliberado, distinto del de 0074: SOLO group_messages, no
-- messages (chat 1:1) -- con un único interlocutor real, "@mencionar" no
-- tiene equivalente real en ninguna de las tres apps de referencia (ya
-- sabes con quién hablas). Reutiliza private.extract_mentioned_profile_ids
-- (0074) tal cual -- misma detección de "@usuario" real, sin duplicar
-- lógica. Comprobación de integridad real añadida aquí que 0074 no
-- necesitaba: sin filtrar por private.is_group_member (0057_group_chats.sql),
-- @mencionar a alguien que NO es miembro del grupo le generaría un aviso
-- real sobre un group_chat_id al que no tiene ningún acceso -- una fuga de
-- privacidad real (aunque el propio RLS ya le impida abrir el mensaje en
-- sí, el aviso en sí ya revela que ese grupo existe y que alguien habló en
-- él).
-- ============================================================================

create or replace function private.notify_mentions_in_group_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mentioned_id uuid;
begin
  for v_mentioned_id in select * from private.extract_mentioned_profile_ids(new.body, new.sender_id)
  loop
    if private.is_group_member(new.group_chat_id, v_mentioned_id) then
      insert into public.notifications (recipient_id, actor_id, kind, payload)
      values (
        v_mentioned_id,
        new.sender_id,
        'mention',
        jsonb_build_object('actor_id', new.sender_id, 'group_chat_id', new.group_chat_id, 'group_message_id', new.id)
      );
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_mentions_in_group_message on group_messages;
create trigger trg_notify_mentions_in_group_message
  after insert on group_messages
  for each row execute function private.notify_mentions_in_group_message();
