-- ============================================================================
-- SOCIAL — Reacciones a mensajes de grupo, comparado con WhatsApp/
-- Messenger/Instagram: las tres dejan reaccionar con un emoji a un mensaje
-- de grupo, igual que ya se podía en el chat 1:1 desde 0018_message_reactions.sql.
-- Hueco real documentado explícitamente en 0058_group_message_notify.sql/
-- LOOP_STATE.md ("reacciones/voz/read-receipts en chats de grupo") --
-- primera pieza, mismo orden que Reels (comentarios llegaron después de
-- la UI base).
--
-- Mismo diseño exacto que message_reactions (0018): tabla propia, una
-- reacción por persona por emoji (varios miembros pueden reaccionar,
-- incluso con emojis distintos), `group_chat_id` desnormalizado para
-- poder cargar las reacciones de un grupo entero con un `eq` simple en
-- vez de un `isIn` sobre una lista de message_id.
-- ============================================================================

create table group_message_reactions (
    id uuid primary key default uuid_generate_v4(),
    group_message_id uuid not null references group_messages(id) on delete cascade,
    group_chat_id uuid not null references group_chats(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    emoji text not null,
    created_at timestamptz not null default now(),
    unique (group_message_id, user_id, emoji)
);

create index if not exists idx_group_message_reactions_message on group_message_reactions(group_message_id);
create index if not exists idx_group_message_reactions_group on group_message_reactions(group_chat_id);

alter table group_message_reactions enable row level security;

-- Mismo criterio que message_reactions_select/_insert (0018): solo
-- miembros reales del grupo -- reutiliza `private.is_group_member`
-- (0057_group_chats.sql) en vez de un `exists` inline (aquí no habría
-- recursión real porque esta tabla es distinta de `group_chat_members`,
-- pero la función ya existe y es la misma comprobación de verdad).
create policy group_message_reactions_select on group_message_reactions
    for select
    using (private.is_group_member(group_message_reactions.group_chat_id, (select auth.uid())));

create policy group_message_reactions_insert on group_message_reactions
    for insert
    with check (
        user_id = (select auth.uid())
        and private.is_group_member(group_message_reactions.group_chat_id, (select auth.uid()))
    );

create policy group_message_reactions_delete_own on group_message_reactions
    for delete
    using (user_id = (select auth.uid()));
