-- ============================================================================
-- SOCIAL — Fase 9: borrar el propio mensaje
--
-- Hallazgo real, mismo patrón que socials/compat_requests: `messages` no
-- tenía NINGUNA política de delete — un mensaje enviado por error o del
-- que te arrepientes se quedaba para siempre, sin forma de borrarlo, ni
-- siquiera el propio remitente. Solo el remitente puede borrar su propio
-- mensaje ("borrar para todos", no un borrado solo-para-mí — SOCIAL no
-- tiene infraestructura de "ocultar por usuario", mismo criterio simple
-- que el resto del chat).
-- ============================================================================

create policy messages_delete_own on messages
    for delete
    using (sender_id = (select auth.uid()));
