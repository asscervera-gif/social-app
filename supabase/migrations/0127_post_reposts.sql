-- ============================================================================
-- SOCIAL — Repostear una publicación real, comparado con Twitter/X
-- ("Retweet") y Facebook ("Compartir")
--
-- Hallazgo real: SOCIAL ya tenía "enviar por mensaje" (SendPostSheet.kt/
-- .swift) y "guardar en colecciones" (0125_saved_post_collections.sql),
-- pero ningún concepto de redistribuir una publicación ajena a TUS
-- propios seguidores -- confirmado con `grep` de "repost"/"reposted" sin
-- resultados en todo el repo. Mismo patrón real exacto que `likes`
-- (0007_likes.sql): tabla propia, `unique(post_id, user_id)`, visible
-- para cualquiera (así se sabe cuántos reposts reales tiene un post,
-- igual que el contador de "me gusta"), solo el propio usuario puede
-- crear/borrar su propio repost.
--
-- Sin contador cacheado en `posts` a propósito -- a diferencia de
-- `likes`/`comments` (si tienen su propio trigger de sync), el número de
-- reposts se calcula real con un `count()` bajo demanda al abrir el
-- detalle de la publicación, mismo criterio de "no todo necesita cache"
-- ya aplicado en varias tablas de preferencia puramente privada de esta
-- sesión -- aquí es pública pero de bajo volumen esperado, sin
-- necesidad real de optimizar antes de tener el problema.
-- ============================================================================

create table post_reposts (
    id uuid primary key default uuid_generate_v4(),
    post_id uuid not null references posts(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (post_id, user_id)
);

create index if not exists idx_post_reposts_post on post_reposts(post_id);
create index if not exists idx_post_reposts_user on post_reposts(user_id, created_at desc);

alter table post_reposts enable row level security;

-- Público, mismo criterio real que likes_select (0007_likes.sql): hace
-- falta que CUALQUIERA pueda ver quién reposteó qué, tanto para el
-- contador real como para que el feed de un seguidor sepa "reposteado
-- por X" de una publicación de un tercero que ni sigue.
create policy post_reposts_select on post_reposts
    for select
    using (true);

create policy post_reposts_insert_own on post_reposts
    for insert
    with check (user_id = (select auth.uid()));

create policy post_reposts_delete_own on post_reposts
    for delete
    using (user_id = (select auth.uid()));

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response', 'repost'));

create or replace function private.notify_new_repost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.posts where id = new.post_id;
  if v_author_id is not null and v_author_id <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.user_id,
      'repost',
      jsonb_build_object('actor_id', new.user_id, 'post_id', new.post_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_repost on post_reposts;
create trigger trg_notify_new_repost
  after insert on post_reposts
  for each row execute function private.notify_new_repost();
