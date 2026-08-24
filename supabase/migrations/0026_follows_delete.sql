-- ============================================================================
-- SOCIAL — Fase 9 (continuación): falta política de borrado en `follows`
--
-- Hallazgo real, mismo patrón que 0020_socials_delete.sql /
-- 0022_messages_delete.sql: `FollowManager.kt`/`FollowManager.swift.unfollow()`
-- ya llaman a `.delete()` sobre `follows`, pero nunca existió ninguna
-- política RLS de borrado para esa tabla — sin política, Postgres deniega
-- el delete por defecto (RLS "closed by default"), así que la llamada no
-- lanza excepción (no hay fila que RLS deje borrar, así que "tiene éxito"
-- borrando cero filas) pero la relación de "seguir" nunca desaparece de
-- verdad: dejar de seguir a alguien no funcionaba en ninguna plataforma
-- desde que se construyó la función, sin que ningún error lo delatara.
-- ============================================================================

create policy follows_delete on follows
    for delete
    using (follower_id = (select auth.uid()));
