-- ============================================================================
-- SOCIAL — `post_id`/`reel_id` real en el payload de comment_like/
-- reel_comment_like, comparado con Instagram/Twitter/Facebook
--
-- Hallazgo real, encontrado auditando el mismo tap muerto ya cerrado para
-- `like`/`comment`/`group_message` (ver PostDetailScreen.kt/PostDetailView.swift,
-- ronda anterior): a diferencia de esos tres, `comment_like`
-- (0054_comment_likes.sql) solo lleva `comment_id` en su payload, nunca
-- `post_id` -- así que aunque el cliente quisiera abrir la publicación
-- real al tocar ese aviso, no tenía ningún dato con el que hacerlo sin una
-- consulta extra en cada tap. Mismo hueco exacto para `reel_comment_like`
-- (solo `reel_comment_id`, nunca `reel_id`).
--
-- Se resuelve en el propio servidor, en el momento de crear el aviso (un
-- solo `select` adicional, ya disponible ahí mismo desde la fila recién
-- insertada) -- exactamente el mismo criterio ya usado para `like`/
-- `comment`, que sí llevan `post_id` en su payload desde el principio
-- (0007/0008). `reel_like`/`reel_comment` (0050_reels.sql) ya llevaban
-- `reel_id` directo, sin cambios ahí.
-- ============================================================================

create or replace function private.notify_new_comment_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
  v_post_id uuid;
begin
  select author_id, post_id into v_author_id, v_post_id from public.comments where id = new.comment_id;
  if v_author_id is not null and v_author_id <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.user_id,
      'comment_like',
      jsonb_build_object('actor_id', new.user_id, 'comment_id', new.comment_id, 'post_id', v_post_id)
    );
  end if;
  return new;
end;
$$;

revoke execute on function private.notify_new_comment_like() from public, anon, authenticated;

create or replace function private.notify_new_reel_comment_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
  v_reel_id uuid;
begin
  select author_id, reel_id into v_author_id, v_reel_id from public.reel_comments where id = new.reel_comment_id;
  if v_author_id is not null and v_author_id <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.user_id,
      'reel_comment_like',
      jsonb_build_object('actor_id', new.user_id, 'reel_comment_id', new.reel_comment_id, 'reel_id', v_reel_id)
    );
  end if;
  return new;
end;
$$;

revoke execute on function private.notify_new_reel_comment_like() from public, anon, authenticated;
