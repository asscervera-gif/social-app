-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo real -- aceptar un social o una
-- solicitud de compatibilidad no notificaba nunca a quien la pidió
--
-- `socials` es la relación central de la app (ver comentario en
-- SocialsListViewModel.swift/.kt) y 0006_notification_triggers.sql ya
-- notifica al DESTINATARIO cuando le llega una solicitud nueva -- pero
-- nadie notifica nunca al REQUESTER cuando esa solicitud se acepta. Quien
-- envía un social por la cámara (SocialCameraView.swift/.kt, único punto
-- de envío) no tiene ninguna otra pantalla que lo mencione: si el otro
-- acepta, el chat se crea en silencio (SocialLinkManager.createChatIfNeeded,
-- llamado desde el cliente del DESTINATARIO) y el emisor solo se entera si
-- por casualidad abre la pestaña Chats y nota uno nuevo. Comparado con
-- Instagram (notifica "X aceptó tu solicitud de seguimiento") o cualquier
-- red con solicitudes bidireccionales, es un hueco real en la función más
-- importante de la app.
--
-- Mismo hueco exacto en `compat_requests` (status idéntico
-- pending/accepted/declined, aceptar tampoco notifica a quien pidió ver
-- el %). Se corrige aquí para ambas tablas con el mismo patrón trigger ya
-- usado en private.increment_event_social_count (0031): AFTER UPDATE,
-- solo dispara en la transición a 'accepted' (old.status is distinct from
-- 'accepted', para no repetir en updates redundantes).
--
-- Un rechazo ('declined') deliberadamente NO notifica -- mismo criterio
-- que Instagram, que tampoco avisa al pedir seguir si te rechazan: no
-- añadir fricción negativa a una solicitud que la otra persona ya decidió
-- ignorar.
-- ============================================================================

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted'));

create or replace function private.notify_social_accepted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'accepted' and (old.status is distinct from 'accepted') then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      new.requester_id,
      new.addressee_id,
      'social_accepted',
      jsonb_build_object('social_id', new.id, 'actor_id', new.addressee_id)
    );
  end if;
  return new;
end;
$$;

revoke execute on function private.notify_social_accepted() from public, anon, authenticated;

drop trigger if exists trg_notify_social_accepted on socials;
create trigger trg_notify_social_accepted
  after update on socials
  for each row execute function private.notify_social_accepted();

create or replace function private.notify_compat_accepted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'accepted' and (old.status is distinct from 'accepted') then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      new.requester_id,
      new.target_id,
      'compat_accepted',
      jsonb_build_object('compat_request_id', new.id, 'actor_id', new.target_id)
    );
  end if;
  return new;
end;
$$;

revoke execute on function private.notify_compat_accepted() from public, anon, authenticated;

drop trigger if exists trg_notify_compat_accepted on compat_requests;
create trigger trg_notify_compat_accepted
  after update on compat_requests
  for each row execute function private.notify_compat_accepted();
