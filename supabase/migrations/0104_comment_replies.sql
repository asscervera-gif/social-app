-- ============================================================================
-- SOCIAL — Responder a un comentario concreto (hilo de un nivel),
-- comparado con Instagram/Facebook/Twitter/TikTok
--
-- Las cuatro apps de referencia dejan responder a un comentario concreto
-- (no solo añadir otro comentario suelto al final), y anidan esa
-- respuesta bajo el comentario original -- Instagram real, en concreto,
-- limita el hilo a UN solo nivel (responder a una respuesta la cuelga
-- del mismo comentario de primer nivel, nunca crea un tercer nivel).
-- Confirmado en el propio código: `comments`/`reel_comments`
-- (0008/0050) son totalmente planos, sin ningún concepto de comentario
-- padre -- ni siquiera `comment_likes` (0054) necesitó esto, porque dar
-- "me gusta" no implica ninguna relación entre comentarios.
--
-- Diseño real: `parent_comment_id`, referencia -- no copia -- al
-- comentario real de primer nivel que se responde. Mismo criterio de
-- "un trigger real en INSERT" ya aplicado a
-- 0102_message_reply.sql/check_reply_same_chat -- aquí además impone el
-- límite real de UN solo nivel (el propio `parent_comment_id` referenciado
-- tiene que ser de primer nivel, `parent_comment_id is null`, igual que
-- Instagram real). `on delete cascade` (no `on delete set null`, a
-- diferencia real de 0102): borrar un comentario real que tiene
-- respuestas se lleva las respuestas con él -- mismo comportamiento real
-- de Instagram/Facebook al borrar un comentario propio, distinto del
-- criterio de un mensaje de chat citado (que sí puede quedar huérfano y
-- seguir teniendo sentido por sí solo).
-- ============================================================================

alter table comments add column parent_comment_id uuid references comments(id) on delete cascade;
alter table reel_comments add column parent_comment_id uuid references reel_comments(id) on delete cascade;

create or replace function private.check_comment_reply_same_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.parent_comment_id is not null and not exists (
    select 1 from public.comments
    where id = new.parent_comment_id
      and post_id = new.post_id
      and parent_comment_id is null
  ) then
    raise exception 'parent_comment_id debe ser un comentario real de primer nivel de la misma publicación';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_comment_reply_same_post on comments;
create trigger trg_check_comment_reply_same_post
  before insert on comments
  for each row execute function private.check_comment_reply_same_post();

create or replace function private.check_reel_comment_reply_same_reel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.parent_comment_id is not null and not exists (
    select 1 from public.reel_comments
    where id = new.parent_comment_id
      and reel_id = new.reel_id
      and parent_comment_id is null
  ) then
    raise exception 'parent_comment_id debe ser un comentario real de primer nivel del mismo reel';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_reel_comment_reply_same_reel on reel_comments;
create trigger trg_check_reel_comment_reply_same_reel
  before insert on reel_comments
  for each row execute function private.check_reel_comment_reply_same_reel();
