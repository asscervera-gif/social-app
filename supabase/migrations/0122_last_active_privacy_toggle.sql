-- ============================================================================
-- SOCIAL — Interruptor recíproco de privacidad para "Últ. vez", comparado
-- con WhatsApp/Telegram
--
-- Hallazgo real, documentado como hueco deliberado desde 0119_last_active_at.sql:
-- "Últ. vez hace..." se mostraba siempre, sin ningún interruptor para
-- desactivarlo -- a diferencia de WhatsApp/Telegram, que sí dejan apagar
-- "Últ. vez" (con la misma regla real y recíproca: si lo apagas, tampoco
-- ves la de los demás). Mismo diseño exacto que
-- profiles.read_receipts_enabled (0091_read_receipts_toggle.sql): el
-- CLIENTE decide si pintar "Últ. vez hace..." mirando el valor real de
-- esta columna en AMBOS perfiles (el propio y el del oponente) -- sin
-- trigger ni política nueva, porque profiles_update_own/profiles_select_public
-- (0002_rls.sql) ya cubren leer/escribir cualquier columna propia/pública.
-- ============================================================================

alter table profiles add column share_last_active boolean not null default true;
