-- ============================================================================
-- SOCIAL — Eliminar un seguidor real, comparado con Instagram/Twitter/
-- Facebook
--
-- Hallazgo real: las tres apps de referencia dejan a QUIEN ES SEGUIDO
-- quitarse de encima a un seguidor concreto sin tener que bloquearlo --
-- distinto de bloquear (que además impide volver a seguir, ver
-- 0011_block_enforcement.sql) y distinto de dejar de seguir (que solo
-- puede hacerlo el propio seguidor sobre su propia fila). Confirmado en
-- el propio código: `follows_delete` (0026_follows_delete.sql) solo deja
-- borrar la fila a `follower_id = auth.uid()` -- quien ES seguido
-- (`followee_id`) no tenía ninguna vía real para quitar a alguien de su
-- propia lista de seguidores.
--
-- Igual que en Instagram real: si la cuenta del seguidor es pública, nada
-- le impide volver a seguir de inmediato (sin política nueva de INSERT,
-- `follows_write_own` de 0011 ya lo permite exactamente igual que
-- cualquier "seguir" normal) -- si de verdad se quiere impedir que
-- vuelva, la herramienta real es bloquear, no esta.
-- ============================================================================

create policy follows_delete_by_followee on follows
    for delete
    using (followee_id = (select auth.uid()));
