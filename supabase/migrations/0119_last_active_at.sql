-- ============================================================================
-- SOCIAL — "Últ. vez hace..." real, comparado con WhatsApp
--
-- `isOpponentOnline` (presencia en vivo por Realtime) ya existe, pero
-- faltaba el estado real cuando la otra persona NO está en línea ahora
-- mismo -- WhatsApp/Telegram siempre muestran cuándo fue la última vez
-- que se la vio, no solo "en línea sí/no". Columna simple en `profiles`,
-- sin política nueva (`profiles_update_own`/`profiles_select_public`,
-- 0002, ya cubren tocar la propia fila y leer la ajena). Alcance
-- deliberado: sin interruptor de privacidad recíproco todavía (WhatsApp
-- real sí lo tiene, "Últ. vez" -- hueco real aparte, documentado para
-- una ronda futura).
-- ============================================================================

alter table profiles add column if not exists last_active_at timestamptz;
