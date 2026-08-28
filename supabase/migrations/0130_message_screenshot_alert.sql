-- ============================================================================
-- SOCIAL — Aviso real de captura de pantalla en el chat, comparado con
-- Snapchat
--
-- Snapchat, la app que originó este patrón, notifica al remitente en
-- cuanto el destinatario hace una captura de pantalla de un snap --
-- confirmado con `grep` de "screenshot"/"FLAG_SECURE"/
-- "UIScreenshotDetected" sin ningún resultado real en todo el repo.
-- SOCIAL ya construyó "foto para ver una vez" (0105_view_once_messages.sql,
-- `view_once`/`opened_at`, el propio SERVIDOR vacía `media_url` al
-- abrirla) y mensajes que desaparecen (0115_disappearing_messages.sql),
-- pero ninguno de los dos avisa si alguien capturó el contenido antes de
-- que desapareciera de verdad -- justo el hueco que Snapchat cierra desde
-- siempre.
--
-- Diseño real: `screenshot_taken_at` (null hasta que el destinatario real
-- hace una captura, protegido igual que `opened_at` -- solo el
-- destinatario puede fijarlo, nunca el remitente, y solo de null a
-- no-null, irreversible). Trigger AFTER UPDATE (no el propio BEFORE
-- UPDATE de protect_message_columns, mismo criterio de separación real ya
-- usado en notify_new_repost/notify_story_share) que avisa al remitente
-- real en cuanto ocurre.
-- ============================================================================

alter table messages add column screenshot_taken_at timestamptz;

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

    if new.is_video is distinct from old.is_video
        and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.is_video := old.is_video;
    end if;

    -- Aviso real de captura de pantalla (0130): screenshot_taken_at solo
    -- puede pasar de null a no-null, y solo lo puede hacer real el
    -- destinatario (nunca el propio remitente) -- mismo criterio real que
    -- opened_at, también irreversible una vez fijado.
    if new.screenshot_taken_at is distinct from old.screenshot_taken_at
        and (old.screenshot_taken_at is not null or v_uid = old.sender_id)
        and current_user <> 'postgres' then
        new.screenshot_taken_at := old.screenshot_taken_at;
    end if;

    return new;
end;
$$;

create or replace function private.notify_message_screenshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.screenshot_taken_at is null and new.screenshot_taken_at is not null then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      new.sender_id,
      (select auth.uid()),
      'screenshot',
      jsonb_build_object('actor_id', (select auth.uid()), 'chat_id', new.chat_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_message_screenshot on messages;
create trigger trg_notify_message_screenshot
  after update on messages
  for each row
  when (old.screenshot_taken_at is null and new.screenshot_taken_at is not null)
  execute function private.notify_message_screenshot();

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response', 'repost', 'story_share', 'screenshot'));
