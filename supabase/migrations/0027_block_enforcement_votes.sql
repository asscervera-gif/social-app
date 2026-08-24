-- ============================================================================
-- SOCIAL — Fase 9 (continuación): bloqueo aplicado también a votos de compatibilidad
--
-- Mismo hallazgo y mismo patrón que 0025_block_enforcement_reactions.sql:
-- `compatibility_votes_insert` (0002_rls.sql) nunca comprobaba `blocks` —
-- votar +100/-100 la compatibilidad de un chat con alguien a quien acabas
-- de bloquear (o que te bloqueó) seguía siendo posible, aunque los
-- mensajes nuevos ya estuvieran bloqueados desde 0013. Bloquear a alguien
-- tiene que detener también los votos de compatibilidad sobre ese chat.
-- ============================================================================

drop policy if exists compatibility_votes_insert on compatibility_votes;
create policy compatibility_votes_insert on compatibility_votes
    for insert
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = compatibility_votes.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
        and not private.is_blocked(
            (select auth.uid()),
            (select case when chats.user_a_id = (select auth.uid()) then chats.user_b_id else chats.user_a_id end
             from chats where chats.id = compatibility_votes.chat_id)
        )
    );
