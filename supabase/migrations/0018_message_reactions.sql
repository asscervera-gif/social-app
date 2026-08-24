-- ============================================================================
-- SOCIAL — Fase 9: reacciones a mensajes (última pieza alcanzable de
-- "chat funcional con fotos, voz, reacciones, read receipts" — solo queda
-- voz, que necesita grabación de audio nativa, un alcance de diseño
-- propio y distinto, documentado aparte).
--
-- Tabla nueva en vez de columna en `messages`: una reacción es por
-- persona, no por mensaje (varios miembros del chat pueden reaccionar,
-- incluso con emojis distintos) — mismo criterio que `likes` (tabla propia,
-- no una columna de contador ingenua) en 0007_likes.sql.
-- ============================================================================

create table message_reactions (
    id uuid primary key default uuid_generate_v4(),
    message_id uuid not null references messages(id) on delete cascade,
    -- Desnormalizado a propósito: sin `chat_id` aquí habría que filtrar
    -- por una lista de message_id (`isIn`/`in_`), sin precedente verificado
    -- contra el compilador real en este proyecto (mismo motivo por el que
    -- otros filtros se evitan si no están probados) — con chat_id, cargar
    -- las reacciones de un chat entero es un `eq` simple, mismo patrón que
    -- messages_select.
    chat_id uuid not null references chats(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    emoji text not null,
    created_at timestamptz not null default now(),
    unique (message_id, user_id, emoji)
);

alter table message_reactions enable row level security;

create index idx_message_reactions_message on message_reactions(message_id);
create index idx_message_reactions_chat on message_reactions(chat_id);

-- Solo se pueden ver/crear/borrar reacciones de mensajes de un chat del
-- que se es miembro — mismo criterio que messages_select/messages_insert
-- (0002_rls.sql), directo sobre chat_id gracias a la desnormalización.
create policy message_reactions_select on message_reactions
    for select
    using (
        exists (
            select 1 from chats
            where chats.id = message_reactions.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );

create policy message_reactions_insert on message_reactions
    for insert
    with check (
        user_id = (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = message_reactions.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );

create policy message_reactions_delete_own on message_reactions
    for delete
    using (user_id = (select auth.uid()));
