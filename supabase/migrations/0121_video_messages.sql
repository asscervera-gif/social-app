-- ============================================================================
-- SOCIAL — Vídeos reales en el chat (1:1 y grupo), comparado con
-- WhatsApp/Telegram/iMessage
--
-- `messages`/`group_messages` ya soportan foto (`media_url`) y nota de
-- voz (`audio_url`), pero ningún mensaje podía llevar un vídeo real --
-- confirmado en el propio esquema. Reutiliza `media_url` tal cual (ya es
-- una URL de Storage, real tanto para foto como para vídeo) más una
-- columna real `is_video` para que el cliente sepa qué reproductor usar
-- -- mismo criterio que `StorageUploader.uploadVideo()` ya usado en
-- Reels, sin subir nada a un bucket ni columna nueva de almacenamiento.
--
-- `is_video` se protege igual que `view_once` (0105): inmutable tras el
-- envío para cualquiera que no sea el propio remitente -- mismo motivo
-- real, evitar que un cliente modificado reescriba de qué tipo es un
-- mensaje ya enviado.
-- ============================================================================

alter table messages add column is_video boolean not null default false;
alter table group_messages add column is_video boolean not null default false;

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
        and v_uid <> old.sender_id;

    if (
        new.body is distinct from old.body
        or new.audio_url is distinct from old.audio_url
        or new.edited_at is distinct from old.edited_at
    ) and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;

    if v_is_view_once_consumption then
        new.media_url := null;
    elsif new.media_url is distinct from old.media_url
        and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.media_url := old.media_url;
    end if;

    if new.read_at is distinct from old.read_at
        and v_uid = old.sender_id and current_user <> 'postgres' then
        new.read_at := old.read_at;
    end if;

    if new.delivered_at is distinct from old.delivered_at
        and v_uid = old.sender_id and current_user <> 'postgres' then
        new.delivered_at := old.delivered_at;
    end if;

    if new.pinned_at is not null and new.pinned_by is distinct from v_uid and current_user <> 'postgres' then
        new.pinned_at := old.pinned_at;
        new.pinned_by := old.pinned_by;
    end if;

    if new.view_once is distinct from old.view_once
        and v_uid <> old.sender_id and current_user <> 'postgres' then
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

    if new.deleted_for is distinct from old.deleted_for and current_user <> 'postgres' then
        if not (old.deleted_for <@ new.deleted_for)
           or not (new.deleted_for <@ (old.deleted_for || v_uid))
        then
            new.deleted_for := old.deleted_for;
        end if;
    end if;

    -- Vídeos reales (0121): is_video es inmutable tras el envío para
    -- cualquiera que no sea el propio remitente, mismo criterio que
    -- view_once.
    if new.is_video is distinct from old.is_video
        and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.is_video := old.is_video;
    end if;

    return new;
end;
$$;

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

    if new.deleted_for is distinct from old.deleted_for and current_user <> 'postgres' then
        if not (old.deleted_for <@ new.deleted_for)
           or not (new.deleted_for <@ (old.deleted_for || v_uid))
        then
            new.deleted_for := old.deleted_for;
        end if;
    end if;

    -- Vídeos reales (0121): is_video es inmutable tras el envío para
    -- cualquiera que no sea el propio remitente, mismo criterio que
    -- 1:1 (protect_message_columns).
    if new.is_video is distinct from old.is_video
        and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.is_video := old.is_video;
    end if;

    return new;
end;
$$;
