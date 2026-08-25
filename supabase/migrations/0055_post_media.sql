-- ============================================================================
-- SOCIAL — Publicaciones con varias fotos (carrusel), comparado con
-- Instagram/Facebook: las dos dejan subir hasta varias fotos en una sola
-- publicación y deslizar entre ellas. `posts.media_url` (0001_schema.sql)
-- solo admite UNA foto por publicación -- hueco real de tamaño comparable
-- a Reels, documentado en LOOP_STATE.md tras cerrar el like de comentarios.
--
-- Diseño: `posts.media_url` se mantiene tal cual como la PRIMERA foto (o la
-- única, para cualquier publicación de antes de esta migración) -- así
-- ningún sitio que solo muestra una miniatura (rejilla de Perfil, Guardados,
-- Moderación) necesita cambiar nada. `post_media` guarda SOLO las fotos
-- adicionales (2ª en adelante), mismo patrón de tabla propia que
-- `comment_likes`/`reel_likes`. No hace falta comprobación de bloqueo aquí
-- (a diferencia de likes/comments): quien inserta es siempre el AUTOR de su
-- propia publicación, nunca una interacción sobre contenido ajeno.
-- ============================================================================

create table post_media (
    id uuid primary key default uuid_generate_v4(),
    post_id uuid not null references posts(id) on delete cascade,
    media_url text not null,
    position integer not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists idx_post_media_post on post_media(post_id, position);

alter table post_media enable row level security;

-- Mismo criterio de visibilidad que comments_select (0008_comments.sql):
-- solo puede leer las fotos extra de un post quien pueda leer el post.
create policy post_media_select on post_media
    for select
    using (
        exists (
            select 1 from posts
            where posts.id = post_media.post_id
              and (
                  posts.author_id = (select auth.uid())
                  or posts.is_social_only = false
                  or private.has_accepted_social((select auth.uid()), posts.author_id)
              )
        )
    );

create policy post_media_insert_own on post_media
    for insert
    with check (
        exists (
            select 1 from posts
            where posts.id = post_media.post_id
              and posts.author_id = (select auth.uid())
        )
    );

create policy post_media_delete_own on post_media
    for delete
    using (
        exists (
            select 1 from posts
            where posts.id = post_media.post_id
              and posts.author_id = (select auth.uid())
        )
    );
