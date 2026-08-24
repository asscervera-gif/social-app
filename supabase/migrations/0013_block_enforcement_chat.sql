-- ============================================================================
-- SOCIAL — Fase 8: bloqueo aplicado también al chat (el más importante)
--
-- Continuación de 0011/0012: `messages_insert` (0002_rls.sql) comprobaba
-- que el remitente fuera parte del chat, pero nunca `blocks` — una vez
-- existe un chat (social aceptado o perfil público), bloquear a la otra
-- persona no impedía que siguiera escribiendo. Este es el hueco más
-- importante de los tres (0011 socials/follows/compat_requests, 0012
-- likes/comments, este chat): es el canal de comunicación más directo de
-- la app, y SOCIAL facilita encuentros físicos con desconocidos — bloquear
-- a alguien tiene que detener también los mensajes de verdad.
-- ============================================================================

drop policy if exists messages_insert on messages;
create policy messages_insert on messages
    for insert
    with check (
        sender_id = (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
        and not private.is_blocked(
            (select auth.uid()),
            (select case when chats.user_a_id = (select auth.uid()) then chats.user_b_id else chats.user_a_id end
             from chats where chats.id = messages.chat_id)
        )
    );
