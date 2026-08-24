-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo de integridad real — el cliente
-- podía insertar resultados de duelo falsos directamente
--
-- Continuación de 0034_protect_duel_scoring.sql: esa migración protegía
-- `compatibility_delta`/`explanation`/`completed_at` contra un UPDATE
-- directo, pero el hueco real estaba en el INSERT — `DuelViewModel.kt/
-- .swift` insertaban la fila completa en `duels` (incluido el
-- `compatibility_delta`/`explanation` que la IA le devolvía) directamente
-- desde el cliente. `duels_insert` (0002_rls.sql) solo comprobaba
-- `initiator_id = auth.uid()`, así que un cliente modificado podía
-- insertar cualquier delta/explanation inventado sin haber jugado nunca
-- un duelo real. Corregido en dos partes: la Edge Function `duel-ai`
-- ahora inserta ella misma la fila (con `service_role`, tras verificar
-- que las respuestas corresponden a una sesión real del propio usuario),
-- y aquí se revoca el INSERT directo del cliente por completo — la única
-- forma de crear un `duels` real pasa a ser esa función.
-- ============================================================================

drop policy if exists duels_insert on duels;
