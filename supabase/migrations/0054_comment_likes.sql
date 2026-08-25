-- ============================================================================
-- SOCIAL — Dar "me gusta" a un comentario, comparado con Instagram/
-- Twitter/Facebook: las tres dejan dar like a un comentario concreto, no
-- solo a la publicación entera. Ni `comments` ni `reel_comments`
-- (0008_comments.sql/0050_reels.sql) tenían ningún concepto de "like" —
-- solo se podían leer, escribir y borrar.
--
-- Mismo patrón EXACTO que `likes`/`reel_likes` (0007/0050): tabla propia,
-- `unique(comment_id, user_id)`, contador cacheado en el propio
-- comentario, bloqueo aplicado desde el principio contra el AUTOR del
-- comentario (no el autor del post/reel -- es su comentario el que se
-- está "likeando"). Sin trigger de protección de `like_count`: ni
-- `comments` ni `reel_comments` tienen NINGUNA política de UPDATE (no se
-- pueden editar, solo borrar), así que RLS ya impide que nadie, ni
-- siquiera el autor, manipule el contador a mano -- solo el trigger
-- (con privilegio elevado) puede tocarlo.
-- ============================================================================

alter table comments add column if not exists like_count integer not null default 0;
alter table reel_comments add column if not exists like_count integer not null default 0;

-- ---------------------------------------------------------------------------
-- comment_likes (publicaciones)
-- ---------------------------------------------------------------------------
create table comment_likes (
    id uuid primary key default uuid_generate_v4(),
    comment_id uuid not null references comments(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (comment_id, user_id)
);

create index if not exists idx_comment_likes_comment on comment_likes(comment_id);

alter table comment_likes enable row level security;

create policy comment_likes_select on comment_likes
    for select
    using (true);

create policy comment_likes_insert_own on comment_likes
    for insert
    with check (
        user_id = (select auth.uid())
        and not private.is_blocked(
            user_id,
            (select author_id from comments where comments.id = comment_likes.comment_id)
        )
    );

create policy comment_likes_delete_own on comment_likes
    for delete
    using (user_id = (select auth.uid()));

create or replace function private.sync_comment_like_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    update public.comments set like_count = like_count + 1 where id = new.comment_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update public.comments set like_count = greatest(0, like_count - 1) where id = old.comment_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_comment_like_count on comment_likes;
create trigger trg_sync_comment_like_count
  after insert or delete on comment_likes
  for each row execute function private.sync_comment_like_count();

create or replace function private.notify_new_comment_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.comments where id = new.comment_id;
  if v_author_id is not null and v_author_id <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.user_id,
      'comment_like',
      jsonb_build_object('actor_id', new.user_id, 'comment_id', new.comment_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_comment_like on comment_likes;
create trigger trg_notify_new_comment_like
  after insert on comment_likes
  for each row execute function private.notify_new_comment_like();

-- ---------------------------------------------------------------------------
-- reel_comment_likes (reels) -- mismo patrón exacto que arriba.
-- ---------------------------------------------------------------------------
create table reel_comment_likes (
    id uuid primary key default uuid_generate_v4(),
    reel_comment_id uuid not null references reel_comments(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (reel_comment_id, user_id)
);

create index if not exists idx_reel_comment_likes_comment on reel_comment_likes(reel_comment_id);

alter table reel_comment_likes enable row level security;

create policy reel_comment_likes_select on reel_comment_likes
    for select
    using (true);

create policy reel_comment_likes_insert_own on reel_comment_likes
    for insert
    with check (
        user_id = (select auth.uid())
        and not private.is_blocked(
            user_id,
            (select author_id from reel_comments where reel_comments.id = reel_comment_likes.reel_comment_id)
        )
    );

create policy reel_comment_likes_delete_own on reel_comment_likes
    for delete
    using (user_id = (select auth.uid()));

create or replace function private.sync_reel_comment_like_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    update public.reel_comments set like_count = like_count + 1 where id = new.reel_comment_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update public.reel_comments set like_count = greatest(0, like_count - 1) where id = old.reel_comment_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_reel_comment_like_count on reel_comment_likes;
create trigger trg_sync_reel_comment_like_count
  after insert or delete on reel_comment_likes
  for each row execute function private.sync_reel_comment_like_count();

create or replace function private.notify_new_reel_comment_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.reel_comments where id = new.reel_comment_id;
  if v_author_id is not null and v_author_id <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.user_id,
      'reel_comment_like',
      jsonb_build_object('actor_id', new.user_id, 'reel_comment_id', new.reel_comment_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_reel_comment_like on reel_comment_likes;
create trigger trg_notify_new_reel_comment_like
  after insert on reel_comment_likes
  for each row execute function private.notify_new_reel_comment_like();

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like'));
