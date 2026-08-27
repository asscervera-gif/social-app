-- ============================================================================
-- SOCIAL — "¿Quién puede comentar?", comparado con Twitter/X/TikTok
--
-- Hallazgo real: Twitter/X deja elegir, al publicar, quién puede
-- responder (Todos / Solo a quienes sigues / Solo a quienes mencionas) --
-- TikTok tiene su propia versión (Todos / Amigos / Nadie). Confirmado en
-- el propio código: `comments_disabled` (0086) ya cubre el extremo
-- "Nadie" (cerrar del todo), pero SOCIAL no tenía ningún término medio
-- real entre "todos pueden comentar" y "nadie puede comentar".
--
-- Diseño real, mínimo, reutilizando piezas ya existentes: columna
-- `reply_audience` en `posts`/`reels` (ya cubiertas por
-- `posts_write_own`/`reels_write_own`, ambas `for all`) + una condición
-- añadida a `comments_insert_own`/`reel_comments_insert_own` ya
-- existentes, mismo criterio que 0086_disable_comments.sql: reutilizar
-- lo que ya hay, sin política nueva ni trigger.
--
-- "Solo a quienes sigues": reutiliza `follows` (0001_schema.sql) tal
-- cual -- "seguir" real, no requiere aceptación mutua, igual que en
-- Twitter/X real. "Solo a quienes mencionas": reutiliza
-- `private.extract_mentioned_profile_ids` (0074_mentions.sql) tal cual
-- sobre `posts.caption`/`reels.caption` -- misma detección real de
-- "@usuario", sin duplicar lógica. El propio autor SIEMPRE puede
-- comentar su propia publicación, sea cual sea el valor elegido (mismo
-- criterio real que Twitter/X: responder a tu propio post nunca se
-- bloquea a ti mismo).
-- ============================================================================

alter table posts add column reply_audience text not null default 'everyone'
    check (reply_audience in ('everyone', 'followers', 'mentioned'));
alter table reels add column reply_audience text not null default 'everyone'
    check (reply_audience in ('everyone', 'followers', 'mentioned'));

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
        and exists (
            select 1 from posts
            where posts.id = comments.post_id
              and (
                  posts.reply_audience = 'everyone'
                  or comments.author_id = posts.author_id
                  or (
                      posts.reply_audience = 'followers'
                      and exists (
                          select 1 from follows
                          where follows.follower_id = comments.author_id
                            and follows.followee_id = posts.author_id
                      )
                  )
                  or (
                      posts.reply_audience = 'mentioned'
                      and exists (
                          select 1 from private.extract_mentioned_profile_ids(posts.caption, posts.author_id) as mentioned_id
                          where mentioned_id = comments.author_id
                      )
                  )
              )
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
        and exists (
            select 1 from reels
            where reels.id = reel_comments.reel_id
              and (
                  reels.reply_audience = 'everyone'
                  or reel_comments.author_id = reels.author_id
                  or (
                      reels.reply_audience = 'followers'
                      and exists (
                          select 1 from follows
                          where follows.follower_id = reel_comments.author_id
                            and follows.followee_id = reels.author_id
                      )
                  )
                  or (
                      reels.reply_audience = 'mentioned'
                      and exists (
                          select 1 from private.extract_mentioned_profile_ids(reels.caption, reels.author_id) as mentioned_id
                          where mentioned_id = reel_comments.author_id
                      )
                  )
              )
        )
    );
