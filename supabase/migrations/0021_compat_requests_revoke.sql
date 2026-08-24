-- ============================================================================
-- SOCIAL — Fase 9: revocar una solicitud de compatibilidad aceptada
--
-- Hallazgo real, mismo patrón que 0020_socials_delete.sql: `compat_requests`
-- no tenía ninguna política de delete — una vez aceptada, quien comparte
-- su % de compatibilidad (`target_id`, ver private.has_accepted_compat_request
-- en 0002_rls.sql) no tenía NINGUNA forma de revocarlo, ni siquiera desde
-- la app entera, para siempre. Solo el dueño de la compatibilidad
-- (target_id) puede borrar — a diferencia de socials, esto NO es
-- simétrico: quien pidió verla (requester_id) no puede revocar el acceso
-- de la otra persona a la suya, porque nunca lo concedió.
-- ============================================================================

create policy compat_requests_delete on compat_requests
    for delete
    using (target_id = (select auth.uid()));
