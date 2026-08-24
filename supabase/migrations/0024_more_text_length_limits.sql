-- ============================================================================
-- SOCIAL — Fase 9 (continuación): dos campos de texto más sin límite real
--
-- Hallazgo real: 0023_text_length_limits.sql cerró el hueco en
-- messages/posts/profiles, pero una auditoría de campos de texto
-- insertados desde el cliente encontró dos más sin ningún límite:
-- `profile_sections.content->>'texto'` (las 15 secciones editables del
-- perfil completo, trabajo/estudios/música...) y `reports.reason`/
-- `reports.details` (denuncias). Mismo criterio que 0023: límites
-- generosos pero reales, no arbitrariamente estrictos.
-- ============================================================================

alter table profile_sections add constraint profile_sections_texto_length
    check (char_length(content ->> 'texto') <= 2000);

alter table reports add constraint reports_reason_length
    check (char_length(reason) <= 100);

alter table reports add constraint reports_details_length
    check (details is null or char_length(details) <= 1000);
