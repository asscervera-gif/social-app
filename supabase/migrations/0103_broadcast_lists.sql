-- ============================================================================
-- SOCIAL — Listas de difusión reales, comparado con WhatsApp
--
-- WhatsApp real deja guardar una lista con nombre de destinatarios y
-- mandarle un mensaje de un tirón -- cada persona lo recibe como un
-- mensaje 1:1 NORMAL en su propio chat con quien lo mandó, sin enterarse
-- de quién más lo recibió ni de que existe la lista (a diferencia real
-- de un chat de grupo, donde todos se ven entre sí). Confirmado en el
-- propio código: SOCIAL no tenía ningún concepto de lista de
-- destinatarios reutilizable -- solo `chats` 1:1 y `group_chats`
-- (visibles entre todos los miembros).
--
-- Diseño real: `broadcast_lists` (la lista en sí, con nombre, totalmente
-- privada -- solo su dueño real sabe que existe) + `broadcast_list_members`
-- (a quién incluye). Deliberadamente NO hay ninguna tabla ni concepto de
-- "mensaje de difusión" en sí: mandar a una lista real es, para el
-- propio backend, sencillamente mandar el mismo mensaje real como un
-- INSERT normal en `messages` por cada destinatario (chat 1:1 normal,
-- ya existente) -- exactamente como WhatsApp real: cada copia vive
-- independiente en su propio chat, `messages_insert`
-- (0013_block_enforcement_chat.sql) ya decide por sí sola si un
-- destinatario bloqueado la recibe o no, sin necesitar ninguna lógica
-- nueva de servidor.
-- ============================================================================

create table broadcast_lists (
    id uuid primary key default uuid_generate_v4(),
    owner_id uuid not null references profiles(id) on delete cascade,
    name text not null check (char_length(name) between 1 and 50),
    created_at timestamptz not null default now()
);

alter table broadcast_lists enable row level security;

-- Mismo criterio real que close_friends (0075): totalmente privada,
-- solo su propio dueño sabe que existe.
create policy broadcast_lists_select_own on broadcast_lists
    for select
    using (owner_id = (select auth.uid()));

create policy broadcast_lists_write_own on broadcast_lists
    for all
    using (owner_id = (select auth.uid()))
    with check (owner_id = (select auth.uid()));

create table broadcast_list_members (
    id uuid primary key default uuid_generate_v4(),
    broadcast_list_id uuid not null references broadcast_lists(id) on delete cascade,
    member_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (broadcast_list_id, member_id)
);

alter table broadcast_list_members enable row level security;

create policy broadcast_list_members_select_own on broadcast_list_members
    for select
    using (
        exists (
            select 1 from broadcast_lists
            where broadcast_lists.id = broadcast_list_members.broadcast_list_id
              and broadcast_lists.owner_id = (select auth.uid())
        )
    );

-- No se puede añadir a alguien ya bloqueado (en cualquiera de las dos
-- direcciones) -- mismo criterio real ya aplicado a follows_write_own/
-- close_friends: nunca llegaría a recibir nada de todas formas
-- (messages_insert ya lo impediría al mandar), pero incluirlo en la
-- lista igualmente sería un estado confuso, no uno real.
create policy broadcast_list_members_write_own on broadcast_list_members
    for all
    using (
        exists (
            select 1 from broadcast_lists
            where broadcast_lists.id = broadcast_list_members.broadcast_list_id
              and broadcast_lists.owner_id = (select auth.uid())
        )
    )
    with check (
        exists (
            select 1 from broadcast_lists
            where broadcast_lists.id = broadcast_list_members.broadcast_list_id
              and broadcast_lists.owner_id = (select auth.uid())
        )
        and not private.is_blocked((select auth.uid()), member_id)
    );
