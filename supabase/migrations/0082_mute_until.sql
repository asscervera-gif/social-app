-- ============================================================================
-- SOCIAL — Silenciar temporalmente (con expiración), comparado con
-- WhatsApp/Telegram
--
-- Las dos dejan elegir "8 horas / 1 semana / siempre" al silenciar una
-- conversación, no solo un interruptor binario. Confirmado en el propio
-- código: `chats.muted_by_a/b` (0047_message_notify_mute.sql) y
-- `group_chat_members.muted` (0064_group_chat_mute.sql) son booleanos
-- puros, sin ninguna fecha de expiración -- silenciar es indefinido o
-- nada.
--
-- Diseño real: se AÑADE una columna de expiración opcional junto a cada
-- flag ya existente, sin cambiar su tipo ni su significado -- el flag
-- sigue siendo "¿está silenciado?", la columna nueva es "¿hasta cuándo?"
-- (null = para siempre, mismo criterio ya usado en
-- `profiles.banned_until`/`admin_ban_user`, 0037_admin_ban.sql). No hace
-- falta pg_cron ni ningún trabajo en segundo plano que "desactive" el
-- flag solo al expirar -- la condición de expiración vive directamente en
-- cada sitio que ya comprobaba el flag (mismo criterio exacto que la
-- vista `my_ban_status`, que nunca escribe de vuelta `is_banned`, solo
-- calcula "¿sigue vigente?" en el momento de leer).
-- ============================================================================

alter table chats add column muted_until_a timestamptz;
alter table chats add column muted_until_b timestamptz;

-- Misma protección que ya tenía protect_chat_muted_flags (0047), ampliada
-- para cubrir también las dos columnas de expiración nuevas -- cada quien
-- solo toca su propia fecha, nunca la de la otra persona.
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
    if new.muted_until_a is distinct from old.muted_until_a and (select auth.uid()) <> old.user_a_id and current_user <> 'postgres' then
        new.muted_until_a := old.muted_until_a;
    end if;
    if new.muted_until_b is distinct from old.muted_until_b and (select auth.uid()) <> old.user_b_id and current_user <> 'postgres' then
        new.muted_until_b := old.muted_until_b;
    end if;
    return new;
end;
$$;

-- notify_new_message (0047): un silencio con expiración real ya pasada
-- deja de contar como silenciado, sin que nadie haya tenido que revertir
-- el flag a mano.
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
    v_muted_until_a timestamptz;
    v_muted_until_b timestamptz;
    v_recipient uuid;
begin
    select user_a_id, user_b_id, muted_by_a, muted_by_b, muted_until_a, muted_until_b
      into v_user_a, v_user_b, v_muted_a, v_muted_b, v_muted_until_a, v_muted_until_b
      from public.chats where id = new.chat_id;

    if not found then
        return new;
    end if;

    if new.sender_id = v_user_a then
        v_recipient := v_user_b;
        if v_muted_b and (v_muted_until_b is null or v_muted_until_b > now()) then
            return new;
        end if;
    else
        v_recipient := v_user_a;
        if v_muted_a and (v_muted_until_a is null or v_muted_until_a > now()) then
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

-- group_chat_members (0064): mismo criterio, una sola columna de
-- expiración porque la fila ya es por-miembro.
alter table group_chat_members add column if not exists muted_until timestamptz;

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
    and gcm.user_id <> new.sender_id
    and not (gcm.muted and (gcm.muted_until is null or gcm.muted_until > now()));
  return new;
end;
$$;
