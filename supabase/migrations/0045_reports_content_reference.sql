-- ============================================================================
-- SOCIAL — referencia real al contenido denunciado
--
-- Hallazgo real, comparado con Instagram/TikTok/Facebook: cuando una
-- denuncia venía de un post o un comentario concreto (no del perfil en
-- general), el único rastro era un texto libre y editable por el
-- denunciante -- "Publicación {id}"/"Comentario {id}" -- metido a mano en
-- `details` (ver PostCard/CommentsSheet). ModerationScreen/ModerationView
-- solo mostraban ese texto plano: un admin revisando la cola de denuncias
-- no tenía forma real de ver la publicación o el comentario en cuestión,
-- solo un ID suelto dentro de una frase que además el denunciante podía
-- borrar o cambiar libremente (es un campo de texto editable, "Detalles
-- opcional"). Comparado con cualquier app grande, donde el panel de
-- moderación siempre muestra el contenido real denunciado, este es un
-- hueco real de eficacia de moderación, no cosmético.
--
-- `post_id`/`comment_id` reales, nullable (la mayoría de denuncias siguen
-- siendo sobre el perfil en general, sin post/comentario concreto) --
-- `on delete set null` en vez de cascade: si el contenido se borra
-- después de denunciarse, la denuncia en sí sigue existiendo para el
-- historial de moderación, solo pierde la referencia al contenido ya
-- inexistente.
-- ============================================================================

alter table reports add column post_id uuid references posts(id) on delete set null;
alter table reports add column comment_id uuid references comments(id) on delete set null;

-- ---------------------------------------------------------------------------
-- Sin esto, la referencia de arriba sería decorativa para el caso más
-- delicado: `posts_select`/`comments_select` (0002_rls.sql/0008_comments.sql)
-- solo dejan ver contenido "solo socials" al propio autor o a alguien con
-- social aceptado -- un admin real revisando una denuncia sobre un post
-- "solo socials" de un desconocido se encontraría con la fila vacía, sin
-- poder revisar justo el contenido más sensible. Mismo patrón exacto ya
-- usado para reports_select_admin/ban_appeals_select_admin: una política
-- adicional (las políticas de un mismo comando se combinan con OR), no
-- una modificación de la política existente.
-- ---------------------------------------------------------------------------

create policy posts_select_admin on posts
    for select
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );

create policy comments_select_admin on comments
    for select
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );
