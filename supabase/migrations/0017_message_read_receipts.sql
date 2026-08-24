-- ============================================================================
-- SOCIAL — Fase 9: confirmaciones de lectura en el chat
--
-- Última pieza de "chat funcional con fotos, voz, reacciones, read
-- receipts" que quedaba realmente accesible sin infraestructura nueva
-- (voz necesita grabación nativa, reacciones necesitan más decisiones de
-- diseño — ambas siguen documentadas como pendientes reales). Mismo
-- patrón exacto que `notifications.read_at`, ya usado y probado en toda
-- la app: columna nullable, `null` = no leído.
-- ============================================================================

alter table messages add column if not exists read_at timestamptz;

-- Solo el destinatario (miembro del chat que NO es el remitente) puede
-- marcar un mensaje como leído — el remitente no necesita ni debe poder
-- tocar read_at de sus propios mensajes.
create policy messages_update_read on messages
    for update
    using (
        sender_id <> (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    )
    with check (
        sender_id <> (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );
