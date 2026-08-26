-- ============================================================================
-- SOCIAL — @menciones reales en captions y comentarios, comparado con
-- Instagram/Twitter/TikTok
--
-- Hueco documentado explícitamente como "Pendiente real" en la ronda
-- anterior (0073_profile_username.sql): las tres apps de referencia dejan
-- escribir "@usuario" en un caption o un comentario para enlazarlo al
-- perfil real y avisar a esa persona. SOCIAL no tenía nada de esto -- ni
-- detección, ni notificación -- y no era construible hasta ahora porque
-- no existía ningún handle único al que anclar la mención (`display_name`
-- es texto libre, no único, puede repetirse).
--
-- Alcance deliberado: posts.caption, reels.caption, comments.body y
-- reel_comments.body -- las cuatro superficies de texto público donde
-- Instagram/Twitter/TikTok permiten menciones. Quedan fuera a propósito:
-- chats 1:1/de grupo (texto privado, sin equivalente real de "mención
-- pública" tampoco en esas apps) y profile_sections (texto largo de
-- "sobre mí", no una superficie de publicación puntual).
-- ============================================================================

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention'));

-- Helper compartido (mismo criterio que private.has_accepted_social/
-- private.is_blocked: security definer + search_path vacío + revoke de
-- ejecución directa): busca "@usuario" reales en un texto y devuelve el
-- id de cada perfil mencionado que de verdad existe con ESE username
-- exacto (0073_profile_username.sql), sin auto-mención y sin bloqueo
-- mutuo con quien escribe. `regexp_matches(..., 'g')` + `distinct` evita
-- notificar dos veces si el mismo @usuario aparece repetido en el texto.
create or replace function private.extract_mentioned_profile_ids(p_text text, p_actor_id uuid)
returns setof uuid
language sql
security definer
set search_path = ''
stable
as $$
  select distinct p.id
  from (
    select lower((regexp_matches(coalesce(p_text, ''), '@([a-zA-Z0-9_]{3,20})', 'g'))[1]) as handle
  ) m
  join public.profiles p on p.username = m.handle
  where p.id <> p_actor_id
    and not private.is_blocked(p_actor_id, p.id);
$$;

revoke execute on function private.extract_mentioned_profile_ids(text, uuid) from public, anon, authenticated;
grant execute on function private.extract_mentioned_profile_ids(text, uuid) to authenticated, service_role;

-- posts.caption --------------------------------------------------------
create or replace function private.notify_mentions_in_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mentioned_id uuid;
begin
  for v_mentioned_id in select * from private.extract_mentioned_profile_ids(new.caption, new.author_id)
  loop
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (v_mentioned_id, new.author_id, 'mention', jsonb_build_object('actor_id', new.author_id, 'post_id', new.id));
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_mentions_in_post on posts;
create trigger trg_notify_mentions_in_post
  after insert on posts
  for each row execute function private.notify_mentions_in_post();

-- reels.caption ------------------------------------------------------------
create or replace function private.notify_mentions_in_reel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mentioned_id uuid;
begin
  for v_mentioned_id in select * from private.extract_mentioned_profile_ids(new.caption, new.author_id)
  loop
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (v_mentioned_id, new.author_id, 'mention', jsonb_build_object('actor_id', new.author_id, 'reel_id', new.id));
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_mentions_in_reel on reels;
create trigger trg_notify_mentions_in_reel
  after insert on reels
  for each row execute function private.notify_mentions_in_reel();

-- comments.body ----------------------------------------------------------
create or replace function private.notify_mentions_in_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mentioned_id uuid;
begin
  for v_mentioned_id in select * from private.extract_mentioned_profile_ids(new.body, new.author_id)
  loop
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (v_mentioned_id, new.author_id, 'mention', jsonb_build_object('actor_id', new.author_id, 'post_id', new.post_id, 'comment_id', new.id));
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_mentions_in_comment on comments;
create trigger trg_notify_mentions_in_comment
  after insert on comments
  for each row execute function private.notify_mentions_in_comment();

-- reel_comments.body -------------------------------------------------------
create or replace function private.notify_mentions_in_reel_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mentioned_id uuid;
begin
  for v_mentioned_id in select * from private.extract_mentioned_profile_ids(new.body, new.author_id)
  loop
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (v_mentioned_id, new.author_id, 'mention', jsonb_build_object('actor_id', new.author_id, 'reel_id', new.reel_id, 'comment_id', new.id));
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_mentions_in_reel_comment on reel_comments;
create trigger trg_notify_mentions_in_reel_comment
  after insert on reel_comments
  for each row execute function private.notify_mentions_in_reel_comment();
