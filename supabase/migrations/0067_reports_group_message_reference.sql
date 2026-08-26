-- ============================================================================
-- SOCIAL — referencia real al mensaje de GRUPO denunciado
--
-- Hallazgo real, comparado con Instagram/WhatsApp/Messenger: mismo hueco
-- exacto que 0048_reports_message_reference.sql (chat 1:1), pero en un
-- chat de grupo -- `reports.message_id` (0048) solo referencia `messages`,
-- nunca `group_messages`. La superficie de acoso real en un grupo es, si
-- acaso, MAYOR que en un 1:1 (más gente puede escribir, más gente puede
-- ver), y sin embargo no había ninguna forma de apuntar a qué mensaje
-- concreto de un grupo motivó una denuncia.
--
-- Mismo criterio deliberado que 0048 (no el bypass general de 0045 para
-- posts/comentarios): un mensaje de grupo sigue siendo contenido privado
-- entre los miembros de ESE grupo, no público -- `group_messages_select_admin`
-- solo deja ver un mensaje que esté REALMENTE referenciado por una fila de
-- `reports`, acotado al mínimo necesario para moderar (un admin ve el
-- mensaje denunciado, no el grupo entero).
-- ============================================================================

alter table reports add column group_message_id uuid references group_messages(id) on delete set null;

create policy group_messages_select_admin on group_messages
    for select
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
        and exists (select 1 from reports where reports.group_message_id = group_messages.id)
    );
