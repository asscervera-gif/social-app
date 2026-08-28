-- ============================================================================
-- SOCIAL — Reacciones con emoji variado a un comentario, comparado con
-- Facebook (Me gusta/Me encanta/Me divierte/Me asombra/Me entristece/Me
-- enoja en cualquier comentario)
--
-- SOCIAL ya construyó exactamente este patrón para mensajes de chat
-- (`message_reactions.emoji`, 0018) y mensajes de grupo
-- (`group_message_reactions.emoji`, 0060), pero nunca lo extendió a
-- comentarios de post/reel -- confirmado en el propio código
-- (0054_comment_likes.sql): `comment_likes`/`reel_comment_likes` solo
-- tienen un "me gusta" booleano, sin ninguna columna de emoji.
--
-- Alcance deliberado, distinto de message_reactions a propósito: UNA
-- reacción por persona y comentario (mismo `unique(comment_id, user_id)`
-- ya existente, reutilizado tal cual -- cambiar de emoji es un UPDATE de
-- la fila propia, no un segundo INSERT), no varias reacciones distintas
-- apiladas como si permite message_reactions para un mensaje de chat --
-- más cerca del modelo real de Instagram/LinkedIn (una reacción por
-- persona, elegible) que del de Facebook (que si acumula varias por
-- persona en la misma pieza de contenido). `sync_comment_like_count`/
-- `sync_reel_comment_like_count` (0054) siguen contando igual -- el
-- contador real sigue siendo "cuántas reacciones", el emoji es solo
-- metadato adicional sobre cada una.
-- ============================================================================

alter table comment_likes add column emoji text not null default '❤️'
    check (emoji in ('❤️', '😂', '😮', '😢', '😡', '👍'));
alter table reel_comment_likes add column emoji text not null default '❤️'
    check (emoji in ('❤️', '😂', '😮', '😢', '😡', '👍'));

-- Cambiar de reacción real (mismo criterio que dar/quitar "me gusta"
-- normal) -- ni comments ni reel_comments tienen política de UPDATE
-- (0054), pero comment_likes/reel_comment_likes sí necesitan una ahora:
-- sin esto, cambiar de emoji obligaría a borrar e insertar de nuevo,
-- perdiendo `created_at` real y disparando un aviso duplicado
-- (notify_new_comment_like ya solo escucha INSERT).
create policy comment_likes_update_own on comment_likes
    for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

create policy reel_comment_likes_update_own on reel_comment_likes
    for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

-- comment_id/user_id inmutables tras el insert -- la política de UPDATE
-- de arriba por sí sola no impide reasignar la fila a OTRO comentario u
-- OTRO usuario, solo exige que quien ejecuta el UPDATE sea el dueño
-- actual de la fila.
create or replace function private.protect_comment_like_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.comment_id := old.comment_id;
    new.user_id := old.user_id;
    return new;
end;
$$;

drop trigger if exists trg_protect_comment_like_identity on comment_likes;
create trigger trg_protect_comment_like_identity
  before update on comment_likes
  for each row execute function private.protect_comment_like_identity();

create or replace function private.protect_reel_comment_like_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.reel_comment_id := old.reel_comment_id;
    new.user_id := old.user_id;
    return new;
end;
$$;

drop trigger if exists trg_protect_reel_comment_like_identity on reel_comment_likes;
create trigger trg_protect_reel_comment_like_identity
  before update on reel_comment_likes
  for each row execute function private.protect_reel_comment_like_identity();
