-- ============================================================================
-- SOCIAL — Mensajes que desaparecen real para todo el chat, comparado
-- con WhatsApp/Instagram DM ("Modo desvanecimiento")
--
-- Las dos dejan activar un temporizador real para un chat 1:1 (WhatsApp:
-- 24h/7 días/90 días) -- a partir de ese momento, cualquier mensaje
-- NUEVO desaparece solo tras ese tiempo, para AMBOS lados. Distinto de
-- "ver una vez" (0105_view_once_messages.sql): eso es una foto suelta
-- que el destinatario consume con un toque; esto es un ajuste real del
-- CHAT ENTERO que afecta a TODO mensaje nuevo (texto, foto, audio) sin
-- que nadie tenga que tocar nada. Confirmado en el propio código:
-- `chats`/`messages` no tenían ningún concepto de temporizador real.
--
-- Diseño: `chats.disappearing_seconds` es un ajuste COMPARTIDO del chat
-- (no una preferencia personal por lado, a diferencia de
-- muted_by_a/pinned_by_a) -- mismo criterio real que WhatsApp: cualquiera
-- de los dos puede activarlo/desactivarlo, y afecta a los dos por igual.
-- `chats_update` (0002_rls.sql) ya deja a cualquier participante tocar
-- cualquier columna propia de su chat sin restricción -- mismo criterio
-- ya aplicado a `read_receipts_enabled`/`hide_like_count`, ninguna
-- política nueva necesaria.
--
-- `messages.disappear_at` se calcula SIEMPRE en el servidor (trigger
-- BEFORE INSERT, ignora cualquier valor que mande el cliente) a partir
-- del ajuste vigente del chat EN ESE MOMENTO -- mismo mecanismo real que
-- `seed_chat_compatibility` (0111): nunca confiar en un valor que
-- pudiera venir de un cliente modificado. Activar/desactivar el modo
-- después NO es retroactivo: un mensaje ya enviado conserva su propio
-- `disappear_at` (o su ausencia) para siempre, igual que WhatsApp real.
--
-- `messages_select` (0002_rls.sql, nunca redefinida hasta ahora --
-- confirmado con `grep` en todas las migraciones) se extiende para
-- excluir un mensaje ya caducado, mismo mecanismo real que `stories_select`
-- (`expires_at > now()`). `protect_message_columns` (0049/0089/0105,
-- última versión real, confirmada con `grep` antes de extenderla) se
-- extiende para que `disappear_at` sea inmutable tras el envío -- nadie,
-- ni siquiera el remitente, puede alargar o cancelar el temporizador de
-- un mensaje ya mandado.
--
-- Aviso de honestidad, mismo criterio ya reconocido para `stories`: un
-- mensaje caducado se OCULTA vía RLS en cuanto se vuelve a consultar,
-- nunca se borra de verdad de la base de datos (no hay ningún cron real
-- en este proyecto) -- ni tampoco desaparece en caliente de una pantalla
-- ya cargada en memoria hasta la próxima recarga real.
--
-- Alcance deliberado: solo chat 1:1 en esta ronda, mismo patrón real ya
-- usado varias veces esta sesión (0102/0103) -- `group_messages` se deja
-- para una ronda futura aparte.
-- ============================================================================

alter table chats add column disappearing_seconds integer;
alter table chats add constraint chats_disappearing_seconds_valid
    check (disappearing_seconds is null or disappearing_seconds in (86400, 604800, 7776000));

alter table messages add column disappear_at timestamptz;

create or replace function private.set_message_disappear_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_seconds integer;
begin
    select disappearing_seconds into v_seconds from public.chats where id = new.chat_id;
    if v_seconds is not null then
        new.disappear_at := now() + make_interval(secs => v_seconds);
    else
        new.disappear_at := null;
    end if;
    return new;
end;
$$;

revoke execute on function private.set_message_disappear_at() from public, anon, authenticated;

drop trigger if exists trg_set_message_disappear_at on messages;
create trigger trg_set_message_disappear_at
    before insert on messages
    for each row
    execute function private.set_message_disappear_at();

drop policy if exists messages_select on messages;
create policy messages_select on messages
    for select
    using (
        exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
        and (disappear_at is null or disappear_at > now())
    );

create or replace function private.protect_message_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_is_view_once_consumption boolean;
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

    -- Mensajes que desaparecen (0115_disappearing_messages.sql):
    -- `disappear_at` lo fija SIEMPRE el trigger de INSERT -- inmutable
    -- después para cualquiera, ni siquiera el propio remitente puede
    -- alargar o cancelar el temporizador de un mensaje ya mandado.
    if new.disappear_at is distinct from old.disappear_at and current_user <> 'postgres' then
        new.disappear_at := old.disappear_at;
    end if;

    return new;
end;
$$;
