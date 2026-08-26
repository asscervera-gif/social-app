-- ============================================================================
-- SOCIAL — Mensajes destacados ("Starred messages"), comparado con WhatsApp
--
-- WhatsApp deja destacar CUALQUIER mensaje (propio o ajeno, en un chat 1:1
-- o de grupo) para encontrarlo después en una lista real, en un sitio
-- aparte -- totalmente privado: la otra persona nunca se entera de que se
-- destacó su mensaje. Confirmado en el propio código: `grep` de
-- "starred"/"destacad"/"favorit" en todo el repo no encontró nada -- el
-- único mecanismo parecido que existe (`saved_posts`, 0009) es para
-- publicaciones, no para mensajes de chat.
--
-- Diseño real, mismo patrón que `saved_posts` (privado del usuario, sin
-- contador público) pero con una referencia polimórfica real: un mensaje
-- destacado puede venir de `messages` (1:1) o de `group_messages` (grupo)
-- -- exactamente uno de los dos, nunca los dos ni ninguno (mismo criterio
-- XOR ya usado en `calls.chat_id`/`group_chat_id`, 0083_group_calls.sql).
-- ============================================================================

create table starred_messages (
    id uuid primary key default uuid_generate_v4(),
    user_id uuid not null references profiles(id) on delete cascade,
    message_id uuid references messages(id) on delete cascade,
    group_message_id uuid references group_messages(id) on delete cascade,
    created_at timestamptz not null default now(),
    check (
        (message_id is not null and group_message_id is null)
        or (message_id is null and group_message_id is not null)
    ),
    unique (user_id, message_id),
    unique (user_id, group_message_id)
);

create index if not exists idx_starred_messages_user on starred_messages(user_id, created_at desc);

alter table starred_messages enable row level security;

-- Totalmente privado, mismo criterio que saved_posts: solo el propio
-- usuario ve/crea/borra sus propios destacados -- ni siquiera el autor
-- real del mensaje destacado puede saber que lo está.
create policy starred_messages_select_own on starred_messages
    for select
    using (user_id = (select auth.uid()));

-- Solo se puede destacar un mensaje real al que ya se tiene acceso de
-- verdad: uno de los dos lados reales del chat 1:1, o un miembro real del
-- grupo (private.is_group_member, ya existente desde 0057_group_chats.sql)
-- -- nunca un mensaje ajeno de un chat en el que no se participa.
create policy starred_messages_insert_own on starred_messages
    for insert
    with check (
        user_id = (select auth.uid())
        and (
            (
                message_id is not null
                and exists (
                    select 1 from messages m
                    join chats c on c.id = m.chat_id
                    where m.id = starred_messages.message_id
                      and (c.user_a_id = (select auth.uid()) or c.user_b_id = (select auth.uid()))
                )
            )
            or (
                group_message_id is not null
                and exists (
                    select 1 from group_messages gm
                    where gm.id = starred_messages.group_message_id
                      and private.is_group_member(gm.group_chat_id, (select auth.uid()))
                )
            )
        )
    );

create policy starred_messages_delete_own on starred_messages
    for delete
    using (user_id = (select auth.uid()));
