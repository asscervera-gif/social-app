-- ============================================================================
-- SOCIAL — Archivar publicaciones, comparado con Instagram/Facebook
--
-- Las dos dejan sacar una publicación del perfil público sin borrarla --
-- se puede archivar y luego restaurar cuando se quiera, conservando
-- like_count/comment_count/comentarios reales intactos. Confirmado en el
-- propio código: `MyPostsScreen.kt`/`MyPostsView.swift` ("Tus
-- publicaciones") solo tenía "Editar"/"Borrar" -- o la publicación se
-- queda visible para siempre, o se pierde para siempre, sin término
-- medio real.
-- ============================================================================

alter table posts add column archived_at timestamptz;

-- `posts_write_own` (0002_rls.sql) ya es `for all` sobre cualquier
-- columna propia -- no hace falta ninguna política nueva para poder
-- archivar/restaurar, solo ampliar `posts_select` para que una
-- publicación archivada deje de ser visible para cualquiera que no sea
-- su propio autor (igual que Instagram/Facebook: archivar la saca del
-- perfil público y del feed de cualquier otra persona).
drop policy if exists posts_select on posts;
create policy posts_select on posts
    for select
    using (
        author_id = (select auth.uid())
        or (
            archived_at is null
            and (
                is_social_only = false
                or private.has_accepted_social((select auth.uid()), author_id)
            )
        )
    );

-- Mismo criterio reflejado en comments_select (0008_comments.sql) y
-- post_media_select (0055_post_media.sql): solo puede leer los
-- comentarios/fotos extra de un post quien pueda leer el post en sí --
-- sin esto, los comentarios de una publicación archivada seguirían
-- siendo visibles para un desconocido aunque la publicación en sí ya no
-- lo fuera, una inconsistencia real de privacidad.
drop policy if exists comments_select on comments;
create policy comments_select on comments
    for select
    using (
        exists (
            select 1 from posts
            where posts.id = comments.post_id
              and (
                  posts.author_id = (select auth.uid())
                  or (
                      posts.archived_at is null
                      and (
                          posts.is_social_only = false
                          or private.has_accepted_social((select auth.uid()), posts.author_id)
                      )
                  )
              )
        )
    );

drop policy if exists post_media_select on post_media;
create policy post_media_select on post_media
    for select
    using (
        exists (
            select 1 from posts
            where posts.id = post_media.post_id
              and (
                  posts.author_id = (select auth.uid())
                  or (
                      posts.archived_at is null
                      and (
                          posts.is_social_only = false
                          or private.has_accepted_social((select auth.uid()), posts.author_id)
                      )
                  )
              )
        )
    );
