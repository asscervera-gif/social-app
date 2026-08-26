-- ============================================================================
-- SOCIAL — Confirmación de lectura ("visto por") en chats de grupo,
-- comparado con WhatsApp/Messenger: las dos muestran quién ha leído cada
-- mensaje de un grupo, no solo si se entregó. Segunda pieza del hueco
-- explícitamente documentado desde la ronda de reacciones ("voz/
-- read-receipts en chats de grupo siguen sin construir").
--
-- Diseño distinto del read receipt 1:1 (`messages.read_at`, una sola
-- columna porque solo hay OTRA persona que pueda leerlo) -- en un grupo
-- puede haber leído el mensaje cualquier subconjunto de los demás
-- miembros, así que hace falta una fila por (mensaje, lector), no una
-- columna. Mismo patrón de tabla propia + `group_chat_id` desnormalizado
-- ya usado en 0060_group_message_reactions.sql.
-- ============================================================================

create table group_message_reads (
    id uuid primary key default uuid_generate_v4(),
    group_message_id uuid not null references group_messages(id) on delete cascade,
    group_chat_id uuid not null references group_chats(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    read_at timestamptz not null default now(),
    unique (group_message_id, user_id)
);

create index if not exists idx_group_message_reads_message on group_message_reads(group_message_id);
create index if not exists idx_group_message_reads_group on group_message_reads(group_chat_id);

alter table group_message_reads enable row level security;

-- Cualquier miembro del grupo puede ver quién ha leído qué -- mismo
-- criterio abierto que WhatsApp/Messenger (el recibo de lectura de un
-- grupo no es privado entre dos personas, lo ve cualquier miembro).
create policy group_message_reads_select on group_message_reads
    for select
    using (private.is_group_member(group_message_reads.group_chat_id, (select auth.uid())));

-- Mismo criterio que messages_update_read (0017_message_read_receipts.sql,
-- chat 1:1): solo se puede marcar como leído un mensaje AJENO, nunca el
-- propio -- evita que alguien infle artificialmente cuántas personas han
-- "visto" su propio mensaje.
create policy group_message_reads_insert_own on group_message_reads
    for insert
    with check (
        user_id = (select auth.uid())
        and private.is_group_member(group_message_reads.group_chat_id, (select auth.uid()))
        and exists (
            select 1 from group_messages
            where group_messages.id = group_message_reads.group_message_id
              and group_messages.sender_id <> (select auth.uid())
        )
    );
