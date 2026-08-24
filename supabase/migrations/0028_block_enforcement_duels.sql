-- ============================================================================
-- SOCIAL — Fase 9 (continuación): bloqueo aplicado también a duelos
--
-- Mismo hallazgo y mismo patrón que 0025/0027: `duels_insert`
-- (0002_rls.sql) solo comprobaba `initiator_id = auth.uid()`, nunca
-- `blocks` (ni siquiera que `opponent_id` fuera realmente un socio de
-- algún chat) — retar a un duelo a alguien a quien acabas de bloquear (o
-- que te bloqueó) seguía siendo posible. Bloquear a alguien tiene que
-- detener también los duelos nuevos contra esa persona.
-- ============================================================================

drop policy if exists duels_insert on duels;
create policy duels_insert on duels
    for insert
    with check (
        initiator_id = (select auth.uid())
        and not private.is_blocked(initiator_id, opponent_id)
    );
