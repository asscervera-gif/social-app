-- ============================================================================
-- SOCIAL — Fase 8: bloqueo aplicado también a likes/comments
--
-- Continuación del hallazgo de 0011_block_enforcement.sql: mismo problema
-- en `likes_insert_own`/`comments_insert_own` (0007/0008) — solo
-- comprobaban `user_id/author_id = auth.uid()`, nunca `blocks`. Un usuario
-- bloqueado podía seguir dando like o comentando en los posts de quien lo
-- bloqueó, e incluso generarle una notificación (los triggers de
-- notify_new_like/notify_new_comment no distinguen bloqueo) — bloquear a
-- alguien debe detener también sus interacciones sobre tu contenido, no
-- solo el envío de socials/follows/compat_requests.
-- ============================================================================

drop policy if exists likes_insert_own on likes;
create policy likes_insert_own on likes
    for insert
    with check (
        user_id = (select auth.uid())
        and not private.is_blocked(
            user_id,
            (select author_id from posts where posts.id = likes.post_id)
        )
    );

drop policy if exists comments_insert_own on comments;
create policy comments_insert_own on comments
    for insert
    with check (
        author_id = (select auth.uid())
        and not private.is_blocked(
            author_id,
            (select author_id from posts where posts.id = comments.post_id)
        )
    );
