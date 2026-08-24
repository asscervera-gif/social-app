-- ============================================================================
-- SOCIAL — Fase 8: tabla `likes` real
--
-- Hallazgo real de esta auditoría: HomeViewModel.like() (ambas plataformas)
-- solo hacía una actualización optimista LOCAL de `post.likeCount`, con un
-- comentario honesto ya en el código: "El contador real se recalcula en el
-- backend al insertar el 'like' (fuera del alcance de este código)". Pero
-- ese "backend" nunca existió — no había tabla `likes`, ni RLS, ni trigger
-- que tocara `posts.like_count`. El botón de like está completamente
-- cableado en la UI (HomeScreen.kt/HomeView.swift) pero es enteramente
-- falso: el contador se pierde en el siguiente `load()`, y no hay ningún
-- registro server-side de quién dio like a qué. Mismo tipo de hallazgo que
-- 0006_notification_triggers.sql (funcionalidad visible/cableada que nunca
-- persistía nada real). Se construye aquí la pieza que faltaba.
-- ============================================================================

create table likes (
    id uuid primary key default uuid_generate_v4(),
    post_id uuid not null references posts(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (post_id, user_id)
);

create index if not exists idx_likes_post on likes(post_id);

alter table likes enable row level security;

create policy likes_select on likes
    for select
    using (true);

create policy likes_insert_own on likes
    for insert
    with check (user_id = (select auth.uid()));

create policy likes_delete_own on likes
    for delete
    using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Mantiene posts.like_count sincronizado — mismo patrón security definer +
-- search_path vacío ya usado en el resto de triggers de este proyecto.
-- ---------------------------------------------------------------------------
create or replace function private.sync_post_like_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    update public.posts set like_count = like_count + 1 where id = new.post_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update public.posts set like_count = greatest(0, like_count - 1) where id = old.post_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_post_like_count on likes;
create trigger trg_sync_post_like_count
  after insert or delete on likes
  for each row execute function private.sync_post_like_count();

-- ---------------------------------------------------------------------------
-- Notifica al autor del post cuando alguien le da like — 'like' ya es un
-- kind válido en notifications (0001_schema.sql) y AvisosViewModel.icon()/
-- title() ya lo mostraban ("❤ Le gustó tu publicación"), pero como con
-- socials/follows/etc. (0006_notification_triggers.sql) nunca había ningún
-- productor real: el autor nunca se enteraba de un like. No se notifica un
-- self-like (dar like a tu propio post).
-- ---------------------------------------------------------------------------
create or replace function private.notify_new_like()
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
      'like',
      jsonb_build_object('actor_id', new.user_id, 'post_id', new.post_id)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_new_like on likes;
create trigger trg_notify_new_like
  after insert on likes
  for each row execute function private.notify_new_like();
