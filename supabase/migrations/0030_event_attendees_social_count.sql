-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo de seguridad real — ranking de
-- Modo Evento falseable
--
-- `event_attendees_insert_own` (0003_safety.sql) solo comprueba
-- `profile_id = auth.uid()` — `social_count` (la columna que ordena el
-- ranking del evento, `idx_event_attendees_event ... social_count desc`)
-- no tenía ninguna restricción, así que un cliente modificado podía
-- unirse a un evento insertando directamente `social_count = 999999` y
-- aparecer primero en el ranking sin haber hecho ningún social de
-- verdad. No existe ninguna política de UPDATE sobre esta tabla (así que
-- no se puede inflar después de unirse), pero el valor inicial de la
-- fila sí era libre. Mismo criterio que el hallazgo de `is_verified`:
-- una columna que representa una métrica de confianza no puede quedar en
-- manos del cliente.
-- ============================================================================

drop policy if exists event_attendees_insert_own on event_attendees;
create policy event_attendees_insert_own on event_attendees
    for insert
    with check (
        profile_id = (select auth.uid())
        and social_count = 0
    );
