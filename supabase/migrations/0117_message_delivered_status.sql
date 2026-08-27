-- ============================================================================
-- SOCIAL — Estado real de "Entregado" en un mensaje, comparado con
-- WhatsApp (✓ enviado / ✓✓ gris entregado / ✓✓ azul leído)
--
-- `messages.read_at` (0017) ya cubre "leído", pero faltaba el estado
-- intermedio real más icónico de WhatsApp: "entregado al dispositivo",
-- antes de que lo abra. Mismo mecanismo real que read_at: columna +
-- guardia en protect_message_columns (última versión real, 0115,
-- confirmada con grep) -- solo el DESTINATARIO puede marcarla, nunca el
-- propio remitente, y solo de null a no-null.
-- ============================================================================

alter table messages add column delivered_at timestamptz;

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

    -- Entregado real (0117): mismo criterio que read_at -- solo el
    -- destinatario lo marca, nunca el remitente.
    if new.delivered_at is distinct from old.delivered_at
        and (select auth.uid()) = old.sender_id and current_user <> 'postgres' then
        new.delivered_at := old.delivered_at;
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

    if new.disappear_at is distinct from old.disappear_at and current_user <> 'postgres' then
        new.disappear_at := old.disappear_at;
    end if;

    return new;
end;
$$;
