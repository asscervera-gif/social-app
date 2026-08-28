-- ============================================================================
-- SOCIAL — Aviso real a tus seguidores cuando empiezas un Directo,
-- comparado con Instagram/TikTok ("Fulano está en directo ahora")
--
-- Hallazgo real, confirmado con `grep -n "notif" 0056_live_streams.sql`
-- sin resultados: "empezar un Directo" es el único evento de contenido
-- de primer nivel (comparado con follow/like/comment/mention/repost/
-- story_share/new_post, todos con trigger real en
-- notifications_kind_check) sin ningún aviso real -- arrancar un directo
-- es invisible para tus seguidores salvo que abran la app y lo vean por
-- casualidad en la pestaña correspondiente.
--
-- Diseño real: notifica a los seguidores reales (`follows`, no una
-- suscripción aparte como `new_post`/0098 -- un directo es un evento
-- efímero y urgente, más cerca de "cualquiera que te sigue debería
-- enterarse ahora mismo" que de un post permanente donde sí tiene
-- sentido un opt-in aparte). Mismo patrón de fan-out real (`insert ...
-- select`) ya usado en `notify_post_subscribers` (0098), con el mismo
-- filtro real de bloqueo.
-- ============================================================================

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response', 'repost', 'story_share', 'screenshot', 'live_start'));

create or replace function private.notify_live_start()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  select
    follows.follower_id,
    new.host_id,
    'live_start',
    jsonb_build_object('actor_id', new.host_id, 'stream_id', new.id)
  from public.follows
  where follows.followee_id = new.host_id
    and not private.is_blocked(follows.follower_id, new.host_id);
  return new;
end;
$$;

drop trigger if exists trg_notify_live_start on live_streams;
create trigger trg_notify_live_start
  after insert on live_streams
  for each row execute function private.notify_live_start();
