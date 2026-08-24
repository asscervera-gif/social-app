-- ============================================================================
-- SOCIAL — Fase 8: disparadores de notificaciones
--
-- Hallazgo real de esta auditoría: la tabla `notifications` tiene políticas
-- RLS de select/update (0002_rls.sql) y el cliente (AvisosViewModel en
-- ambas plataformas) ya lee y marca como leídas — pero NINGÚN sitio escribía
-- nunca una fila nueva. Ni trigger en el servidor ni insert en el cliente
-- (y el cliente no podría: no hay política de insert, RLS deniega por
-- defecto). Resultado: la pantalla "Avisos", completamente construida y
-- cableada en ambas plataformas, estaría siempre vacía contra un proyecto
-- real. Se corrige aquí con funciones trigger `security definer` — mismo
-- patrón ya usado en private.has_accepted_social (search_path vacío,
-- nombres de tabla cualificados con public.), que bypasean RLS al insertar
-- en `notifications` en nombre de otro usuario (el destinatario).
--
-- payload usa exactamente las claves que ya esperan AvisosScreen.kt /
-- AvisosView.swift (documentadas ahí como convención): social_id, actor_id,
-- compat_request_id, duel_id, chat_id.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- socials -> notifica al destinatario cuando alguien le envía un social
-- ---------------------------------------------------------------------------
create or replace function private.notify_new_social()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  values (
    new.addressee_id,
    new.requester_id,
    'social',
    jsonb_build_object('social_id', new.id, 'actor_id', new.requester_id)
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_new_social on socials;
create trigger trg_notify_new_social
  after insert on socials
  for each row execute function private.notify_new_social();

-- ---------------------------------------------------------------------------
-- follows -> notifica a quien recibe el follow
-- ---------------------------------------------------------------------------
create or replace function private.notify_new_follow()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  values (
    new.followee_id,
    new.follower_id,
    'follow',
    jsonb_build_object('actor_id', new.follower_id)
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_new_follow on follows;
create trigger trg_notify_new_follow
  after insert on follows
  for each row execute function private.notify_new_follow();

-- ---------------------------------------------------------------------------
-- compat_requests -> notifica al perfil cuya compatibilidad se solicita ver
-- ---------------------------------------------------------------------------
create or replace function private.notify_new_compat_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  values (
    new.target_id,
    new.requester_id,
    'compat_request',
    jsonb_build_object('compat_request_id', new.id, 'actor_id', new.requester_id)
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_new_compat_request on compat_requests;
create trigger trg_notify_new_compat_request
  after insert on compat_requests
  for each row execute function private.notify_new_compat_request();

-- ---------------------------------------------------------------------------
-- duels -> notifica al oponente cuando se completa un duelo (el cliente
-- inserta la fila ya completada, con compatibility_delta/explanation
-- calculados — ver DuelViewModel.save()/finish(), no hay estado "en curso"
-- guardado en la tabla).
-- ---------------------------------------------------------------------------
create or replace function private.notify_duel_completed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  values (
    new.opponent_id,
    new.initiator_id,
    'fight',
    jsonb_build_object('duel_id', new.id, 'chat_id', new.chat_id, 'actor_id', new.initiator_id)
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_duel_completed on duels;
create trigger trg_notify_duel_completed
  after insert on duels
  for each row execute function private.notify_duel_completed();
