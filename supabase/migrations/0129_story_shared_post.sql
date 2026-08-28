-- ============================================================================
-- SOCIAL — Compartir una publicación a tu Historia con atribución al autor
-- original, comparado con Instagram/Facebook ("Add post to your story")
--
-- Hallazgo real: SOCIAL ya tenía "enviar por mensaje" (SendPostSheet.kt/
-- .swift, message_shared_post 0069) y "repostear a tu feed de seguidores"
-- (post_reposts, 0127_post_reposts.sql), pero ningún camino que reutilice el
-- mecanismo de Historia (`stories`, efímera 24h) -- confirmado leyendo
-- `stories` (0001_schema.sql, líneas 60-66): solo `id, author_id, media_url,
-- created_at, expires_at`, sin ninguna columna para referenciar un post
-- original. Instagram/Facebook sí dejan compartir la publicación de otra
-- persona como tu propia historia, con un sticker que muestra de quién es
-- y que se puede tocar para abrir el post original.
--
-- Alcance deliberado: reutiliza `media_url` del propio post (sin pipeline
-- de composición nuevo, sin subir nada nuevo a Storage) -- solo se puede
-- compartir a Historia un post que YA tiene foto/vídeo (`media_url not
-- null`), mismo límite real que reels/historias siempre exigieron. Un post
-- de solo texto no se puede compartir así, igual que ese mismo post no
-- podría ser una Historia por sí solo (`stories.media_url` también
-- `not null`). `shared_post_author_id` desnormalizado a propósito (no solo
-- `shared_post_id`): si el post original se borra después, la atribución
-- real ("Historia de X") sigue siendo correcta en vez de desaparecer.
-- ============================================================================

alter table stories add column shared_post_id uuid references posts(id) on delete set null;
alter table stories add column shared_post_author_id uuid references profiles(id) on delete set null;

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response', 'repost', 'story_share'));

create or replace function private.notify_story_share()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.shared_post_author_id is not null and new.shared_post_author_id <> new.author_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      new.shared_post_author_id,
      new.author_id,
      'story_share',
      jsonb_build_object('actor_id', new.author_id, 'post_id', new.shared_post_id, 'story_id', new.id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_story_share on stories;
create trigger trg_notify_story_share
  after insert on stories
  for each row
  when (new.shared_post_id is not null)
  execute function private.notify_story_share();
