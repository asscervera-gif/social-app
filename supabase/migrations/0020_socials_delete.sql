-- ============================================================================
-- SOCIAL — Fase 9: quitar un social aceptado
--
-- Hallazgo real: `socials` no tenía NINGUNA política de delete — una vez
-- aceptado, el vínculo era permanente para siempre, sin forma de
-- deshacerlo (a diferencia de `follows`, que sí es `for all` y ya
-- permitía dejar de seguir). Cualquiera de las dos partes puede quitar el
-- social, no solo quien lo pidió — un vínculo mutuo se puede deshacer
-- desde cualquiera de los dos lados, mismo criterio que "dejar de
-- seguir" en follows_write_own.
-- ============================================================================

create policy socials_delete on socials
    for delete
    using (
        requester_id = (select auth.uid())
        or addressee_id = (select auth.uid())
    );
