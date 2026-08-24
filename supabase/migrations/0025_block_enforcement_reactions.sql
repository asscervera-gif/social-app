-- ============================================================================
-- SOCIAL — Fase 9 (continuación): bloqueo aplicado también a reacciones de chat
--
-- Continuación de 0013_block_enforcement_chat.sql (mensajes ya bloqueados)
-- y 0012_block_enforcement_posts.sql (likes/comments ya bloqueados):
-- `message_reactions_insert` (0018_message_reactions.sql) solo comprobaba
-- que el usuario fuera miembro del chat, nunca `blocks` — un chat puede
-- seguir existiendo (la fila `chats` no se borra al bloquear) aunque ya no
-- se puedan enviar mensajes nuevos, así que reaccionar con un emoji a un
-- mensaje antiguo de alguien a quien acabas de bloquear (o que te bloqueó)
-- seguía siendo posible. Mismo principio que los otros tres: bloquear a
-- alguien tiene que detener también las reacciones, no solo los mensajes.
-- Mismo patrón exacto que messages_insert (0013), aplicado aquí.
-- ============================================================================

drop policy if exists message_reactions_insert on message_reactions;
create policy message_reactions_insert on message_reactions
    for insert
    with check (
        user_id = (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = message_reactions.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
        and not private.is_blocked(
            (select auth.uid()),
            (select case when chats.user_a_id = (select auth.uid()) then chats.user_b_id else chats.user_a_id end
             from chats where chats.id = message_reactions.chat_id)
        )
    );
