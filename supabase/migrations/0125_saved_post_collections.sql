-- ============================================================================
-- SOCIAL — Colecciones reales para publicaciones guardadas, comparado
-- con Instagram ("Collections")
--
-- Hallazgo real: `saved_posts` (0009_saved_posts.sql) era un simple
-- marcador -- una sola lista plana de "guardado", sin ninguna forma de
-- organizarlos por tema (viajes, recetas, ideas...), a diferencia de
-- Instagram, que deja agrupar lo guardado en colecciones con nombre.
--
-- Diseño deliberadamente ligero: una columna de texto libre en la propia
-- fila, no una tabla de colecciones aparte con su propio id/RLS -- mismo
-- criterio ya usado en `muted_feed_keywords`/`hide_like_count`: es una
-- preferencia puramente del propio dueño de la fila, y
-- `saved_posts_select_own`/`insert_own`/`delete_own` (0009) ya cubren
-- CUALQUIER columna de la fila sin necesitar política nueva. `null`
-- significa "sin colección" (bandeja general, "Todo lo guardado"), mismo
-- criterio que `chats.disappearing_seconds`/`profiles.bio` para "sin
-- valor todavía". Límite de longitud real (50, mismo orden de magnitud
-- que `story_highlights.title`, 0101) para no dejar crecer un nombre sin
-- límite.
-- ============================================================================

alter table saved_posts add column collection_name text;
alter table saved_posts add constraint saved_posts_collection_name_length check (char_length(collection_name) <= 50);

-- Mover un guardado real a otra colección después de guardarlo, mismo
-- criterio real que Instagram -- 0009_saved_posts.sql nunca tuvo
-- política UPDATE (guardar era una decisión de una sola vez: guardar/
-- quitar, nunca editar). `post_id`/`user_id` quedan protegidos por la
-- propia condición `user_id = auth.uid()` en USING/WITH CHECK -- nadie
-- puede "robar" el guardado de otro reescribiendo `user_id`, porque la
-- fila deja de cumplir la condición en cuanto se toca esa columna.
create policy saved_posts_update_own on saved_posts
    for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));
