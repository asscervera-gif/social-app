-- ============================================================================
-- SOCIAL — Fase 8: comentarios reales en publicaciones
--
-- Hueco documentado en LOOP_STATE.md: `posts.comment_count` existía como
-- columna desde el esquema original, y ambas plataformas ya mostraban el
-- contador ("💬 $commentCount") en el feed, pero no había tabla `comments`
-- ni ningún punto de la UI para escribir un comentario — a diferencia del
-- bug de "like" (que sí tenía botón, solo le faltaba persistencia), aquí
-- no existía ningún control interactivo en absoluto. Se construye aquí la
-- pieza completa: tabla, RLS, trigger de contador y trigger de notificación,
-- mismo patrón ya usado en 0006/0007.
-- ============================================================================

create table comments (
    id uuid primary key default uuid_generate_v4(),
    post_id uuid not null references posts(id) on delete cascade,
    author_id uuid not null references profiles(id) on delete cascade,
    body text not null check (char_length(body) between 1 and 500),
    created_at timestamptz not null default now()
);

create index if not exists idx_comments_post on comments(post_id, created_at);

alter table comments enable row level security;

-- Mismo criterio de visibilidad que posts: solo puede leer comentarios de un
-- post quien pueda leer el propio post (autor, público, o social aceptado).
create policy comments_select on comments
    for select
    using (
        exists (
            select 1 from posts
            where posts.id = comments.post_id
              and (
                  posts.author_id = (select auth.uid())
                  or posts.is_social_only = false
                  or private.has_accepted_social((select auth.uid()), posts.author_id)
              )
        )
    );

create policy comments_insert_own on comments
    for insert
    with check (author_id = (select auth.uid()));

create policy comments_delete_own on comments
    for delete
    using (author_id = (select auth.uid()));

-- Mantiene posts.comment_count sincronizado — mismo patrón que
-- private.sync_post_like_count() en 0007_likes.sql.
create or replace function private.sync_post_comment_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    update public.posts set comment_count = comment_count + 1 where id = new.post_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update public.posts set comment_count = greatest(0, comment_count - 1) where id = old.post_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_post_comment_count on comments;
create trigger trg_sync_post_comment_count
  after insert or delete on comments
  for each row execute function private.sync_post_comment_count();

-- Notifica al autor del post cuando alguien comenta — mismo patrón que
-- private.notify_new_like() en 0007_likes.sql. Requiere 'comment' como kind
-- válido en notifications (0001_schema.sql solo tenía social/follow/fight/
-- like/compat_request).
alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment'));

create or replace function private.notify_new_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.posts where id = new.post_id;
  if v_author_id is not null and v_author_id <> new.author_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.author_id,
      'comment',
      jsonb_build_object('actor_id', new.author_id, 'post_id', new.post_id, 'comment_id', new.id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_comment on comments;
create trigger trg_notify_new_comment
  after insert on comments
  for each row execute function private.notify_new_comment();
