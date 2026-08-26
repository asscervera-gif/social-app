-- ============================================================================
-- SOCIAL — Desactivar los comentarios de una publicación, comparado con
-- Instagram/TikTok
--
-- Las dos dejan al autor cerrar los comentarios de UNA publicación
-- concreta sin tener que borrar el post ni bloquear/silenciar a nadie --
-- los comentarios que ya existían se quedan tal cual, solo se cierra la
-- puerta a comentarios NUEVOS. Confirmado en el propio código: `grep` de
-- "comments_disabled"/"disable.*comment"/"allow_comments" en todo el repo
-- no encontró nada -- la única forma real de "cerrar" los comentarios era
-- borrar la publicación entera.
--
-- Diseño real, mínimo: columna booleana en `posts`/`reels` (ya cubiertas
-- por `posts_write_own`/`reels_write_own`, ambas `for all`, así que
-- activar/desactivar ya está permitido a nivel de RLS sin política nueva)
-- y una condición añadida a `comments_insert_own`/`reel_comments_insert_own`
-- ya existentes -- ninguna política nueva, ningún trigger, mismo criterio
-- que "archivar publicaciones" (0076): reutilizar lo que ya hay.
-- ============================================================================

alter table posts add column comments_disabled boolean not null default false;
alter table reels add column comments_disabled boolean not null default false;

drop policy if exists comments_insert_own on comments;
create policy comments_insert_own on comments
    for insert
    with check (
        author_id = (select auth.uid())
        and not private.is_blocked(
            author_id,
            (select author_id from posts where posts.id = comments.post_id)
        )
        and not exists (
            select 1 from posts
            where posts.id = comments.post_id
              and posts.comments_disabled = true
        )
    );

drop policy if exists reel_comments_insert_own on reel_comments;
create policy reel_comments_insert_own on reel_comments
    for insert
    with check (
        author_id = (select auth.uid())
        and not private.is_blocked(
            author_id,
            (select author_id from reels where reels.id = reel_comments.reel_id)
        )
        and not exists (
            select 1 from reels
            where reels.id = reel_comments.reel_id
              and reels.comments_disabled = true
        )
    );
