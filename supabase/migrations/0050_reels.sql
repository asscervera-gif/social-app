-- ============================================================================
-- SOCIAL — Reels (vídeo corto), primer hueco real de un proyecto grande
-- pedido explícitamente por el usuario tras leer el boceto completo de
-- SOCIAL_APP.html: "lo quiero exactamente igual", incluyendo Reels y "En
-- directo" aunque sea un proyecto grande de varias pasadas.
--
-- Esta pasada cubre SOLO el backend (tabla, RLS, contadores, notificaciones)
-- -- la UI de cliente (subida de vídeo, reproductor, feed) y "En directo"
-- (que necesita un servidor de streaming real, ver LOOP_STATE.md) son huecos
-- reales de pasadas siguientes, no fingidos aquí.
--
-- `reels` es una tabla propia (no una columna extra en `posts`) porque el
-- boceto los trata como una sección y un feed separados de las publicaciones
-- normales (contador propio, pestaña propia dentro de Perfil) -- mismo
-- criterio de "una tabla por concepto real" ya usado para posts/stories.
-- Mismo patrón EXACTO que posts (0001/0002) + likes (0007) + comments (0008):
-- visibilidad social-only, contadores protegidos por trigger, notificación
-- al autor sin autonotificarse.
-- ============================================================================

create table reels (
    id uuid primary key default uuid_generate_v4(),
    author_id uuid not null references profiles(id) on delete cascade,
    video_url text not null,
    thumbnail_url text,
    caption text check (char_length(caption) <= 2200),
    is_social_only boolean not null default false,
    like_count integer not null default 0,
    comment_count integer not null default 0,
    view_count integer not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists idx_reels_author_id on reels(author_id);
create index if not exists idx_reels_created_at on reels(created_at desc);

alter table reels enable row level security;

-- Misma regla 2 que posts_select (0002_rls.sql): autor, público, o social
-- aceptado si is_social_only.
create policy reels_select on reels
    for select
    using (
        author_id = (select auth.uid())
        or is_social_only = false
        or private.has_accepted_social((select auth.uid()), author_id)
    );

create policy reels_write_own on reels
    for all
    using (author_id = (select auth.uid()))
    with check (author_id = (select auth.uid()));

-- Mismo patrón que private.protect_post_counts() (0033): impide que el
-- propio autor (único que puede hacer UPDATE vía reels_write_own) manipule
-- sus contadores a mano en la misma sentencia que edita caption/video_url.
create or replace function private.protect_reel_counts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if pg_trigger_depth() <= 1 then
        new.like_count := old.like_count;
        new.comment_count := old.comment_count;
        new.view_count := old.view_count;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_reel_counts() from public, anon, authenticated;

drop trigger if exists trg_protect_reel_counts on reels;
create trigger trg_protect_reel_counts
    before update on reels
    for each row
    execute function private.protect_reel_counts();

-- ---------------------------------------------------------------------------
-- reel_likes — mismo esquema que likes (0007), apuntando a reels en vez de
-- posts.
-- ---------------------------------------------------------------------------
create table reel_likes (
    id uuid primary key default uuid_generate_v4(),
    reel_id uuid not null references reels(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (reel_id, user_id)
);

create index if not exists idx_reel_likes_reel on reel_likes(reel_id);

alter table reel_likes enable row level security;

create policy reel_likes_select on reel_likes
    for select
    using (true);

-- Mismo criterio que likes_insert_own tras 0012_block_enforcement_posts.sql
-- (aplicado aquí desde el principio, no como un hallazgo dormido aparte):
-- bloquear a alguien debe detener también sus interacciones sobre tu
-- contenido, reels incluidos.
create policy reel_likes_insert_own on reel_likes
    for insert
    with check (
        user_id = (select auth.uid())
        and not private.is_blocked(
            user_id,
            (select author_id from reels where reels.id = reel_likes.reel_id)
        )
    );

create policy reel_likes_delete_own on reel_likes
    for delete
    using (user_id = (select auth.uid()));

create or replace function private.sync_reel_like_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    update public.reels set like_count = like_count + 1 where id = new.reel_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update public.reels set like_count = greatest(0, like_count - 1) where id = old.reel_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_reel_like_count on reel_likes;
create trigger trg_sync_reel_like_count
  after insert or delete on reel_likes
  for each row execute function private.sync_reel_like_count();

create or replace function private.notify_new_reel_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.reels where id = new.reel_id;
  if v_author_id is not null and v_author_id <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.user_id,
      'reel_like',
      jsonb_build_object('actor_id', new.user_id, 'reel_id', new.reel_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_reel_like on reel_likes;
create trigger trg_notify_new_reel_like
  after insert on reel_likes
  for each row execute function private.notify_new_reel_like();

-- ---------------------------------------------------------------------------
-- reel_comments — mismo esquema que comments (0008), apuntando a reels.
-- ---------------------------------------------------------------------------
create table reel_comments (
    id uuid primary key default uuid_generate_v4(),
    reel_id uuid not null references reels(id) on delete cascade,
    author_id uuid not null references profiles(id) on delete cascade,
    body text not null check (char_length(body) between 1 and 500),
    created_at timestamptz not null default now()
);

create index if not exists idx_reel_comments_reel on reel_comments(reel_id, created_at);

alter table reel_comments enable row level security;

create policy reel_comments_select on reel_comments
    for select
    using (
        exists (
            select 1 from reels
            where reels.id = reel_comments.reel_id
              and (
                  reels.author_id = (select auth.uid())
                  or reels.is_social_only = false
                  or private.has_accepted_social((select auth.uid()), reels.author_id)
              )
        )
    );

-- Mismo criterio que comments_insert_own tras 0012_block_enforcement_posts.sql.
create policy reel_comments_insert_own on reel_comments
    for insert
    with check (
        author_id = (select auth.uid())
        and not private.is_blocked(
            author_id,
            (select author_id from reels where reels.id = reel_comments.reel_id)
        )
    );

create policy reel_comments_delete_own on reel_comments
    for delete
    using (author_id = (select auth.uid()));

create or replace function private.sync_reel_comment_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    update public.reels set comment_count = comment_count + 1 where id = new.reel_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update public.reels set comment_count = greatest(0, comment_count - 1) where id = old.reel_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_reel_comment_count on reel_comments;
create trigger trg_sync_reel_comment_count
  after insert or delete on reel_comments
  for each row execute function private.sync_reel_comment_count();

create or replace function private.notify_new_reel_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.reels where id = new.reel_id;
  if v_author_id is not null and v_author_id <> new.author_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.author_id,
      'reel_comment',
      jsonb_build_object('actor_id', new.author_id, 'reel_id', new.reel_id, 'comment_id', new.id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_reel_comment on reel_comments;
create trigger trg_notify_new_reel_comment
  after insert on reel_comments
  for each row execute function private.notify_new_reel_comment();

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment'));
