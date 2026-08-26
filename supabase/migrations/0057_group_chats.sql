-- ============================================================================
-- SOCIAL — Chats de grupo, comparado con WhatsApp/Instagram/Messenger/
-- Facebook: las cuatro dejan crear una conversación con varias personas a
-- la vez, no solo 1 a 1. `chats` (0001_schema.sql) es estrictamente 1:1
-- (`user_a_id`/`user_b_id`, `unique(user_a_id, user_b_id)`, `check
-- (user_a_id <> user_b_id)`) -- no hay forma de tener una conversación de
-- grupo en ninguna plataforma, hueco real de tamaño comparable a Reels/
-- Directo, identificado tras cerrarlos.
--
-- Diseño: tablas NUEVAS y paralelas (`group_chats`/`group_chat_members`/
-- `group_messages`), no una migración invasiva de `chats`/`messages` para
-- soportar N usuarios -- mismo criterio de "tabla propia en vez de
-- complicar una compartida" ya usado repetidamente en este proyecto
-- (`reel_comments` en vez de generalizar `comments`, `reel_likes` en vez
-- de generalizar `likes`). Cero cambios de RLS en el chat 1:1 ya
-- construido y probado -- riesgo de regresión mínimo.
--
-- Esta es la RONDA DE BACKEND (mismo orden que Reels/Directo) -- cliente
-- (crear grupo, añadir miembros, lista de chats de grupo, hilo de
-- mensajes) en una ronda aparte. Sin reacciones/voz/read-receipts todavía
-- (mismo criterio que Reels: comentarios llegaron en una ronda posterior a
-- la UI base), documentado como hueco real, no fingido.
-- ============================================================================

create table group_chats (
    id uuid primary key default uuid_generate_v4(),
    name text not null check (char_length(name) between 1 and 100),
    created_by uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now()
);

alter table group_chats enable row level security;

create table group_chat_members (
    id uuid primary key default uuid_generate_v4(),
    group_chat_id uuid not null references group_chats(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    joined_at timestamptz not null default now(),
    unique (group_chat_id, user_id)
);

create index if not exists idx_group_chat_members_group on group_chat_members(group_chat_id);
create index if not exists idx_group_chat_members_user on group_chat_members(user_id);

alter table group_chat_members enable row level security;

-- Hallazgo real de Postgres/RLS (encontrado por el propio arnés de
-- pruebas al escribir esta migración): `group_chat_members_select`
-- necesita comprobar la pertenencia contra la MISMA tabla que protege --
-- inlinear ese `exists` ahí mismo dispara "infinite recursion detected in
-- policy for relation group_chat_members" (Postgres re-evalúa la propia
-- política RLS para resolver la subconsulta, que a su vez la vuelve a
-- evaluar...). Mismo motivo exacto por el que `is_blocked`/
-- `has_accepted_social` son funciones `security definer` en vez de
-- subconsultas inline: una función con privilegio elevado consulta la
-- tabla SIN pasar por RLS, rompiendo el ciclo. `is_group_member` se
-- reutiliza en las tres políticas que necesitan esta comprobación
-- (`group_chats_select`, `group_chat_members_select`/`_insert`,
-- `group_messages_select`/`_insert`).
create or replace function private.is_group_member(p_group_chat_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.group_chat_members
    where group_chat_id = p_group_chat_id and user_id = p_user_id
  );
$$;

revoke execute on function private.is_group_member(uuid, uuid) from public, anon, authenticated;
grant execute on function private.is_group_member(uuid, uuid) to authenticated, service_role;

-- Solo miembros reales ven el grupo -- el creador se añade a sí mismo
-- como miembro automáticamente (trigger de más abajo), nunca queda un
-- grupo real sin que su creador aparezca en la lista de miembros.
create policy group_chats_select on group_chats
    for select
    using (private.is_group_member(group_chats.id, (select auth.uid())));

create policy group_chats_insert_own on group_chats
    for insert
    with check (created_by = (select auth.uid()));

-- Aviso real para el cliente (Kotlin/Swift), confirmado con el propio
-- arnés de pruebas: `insert into group_chats (...) returning id` (o el
-- equivalente `.insert(...) { select() }`/`.insert(...).select().single()`
-- ya usado para `posts`/`live_streams`) FALLA aquí con "new row violates
-- row-level security policy for table group_chats" -- RETURNING vuelve a
-- comprobar la fila contra `group_chats_select` (que depende de
-- `is_group_member`, que a su vez depende de que el trigger de más abajo
-- YA haya insertado la fila de pertenencia del creador) en un punto
-- anterior a que ese efecto del trigger cuente para esa comprobación
-- concreta -- aunque sí cuenta ya para cualquier SELECT posterior real
-- (verificado). El cliente debe generar el `id` él mismo (UUID.randomUUID()/
-- UUID()) e insertarlo explícito, en vez de depender de RETURNING para
-- esta tabla en concreto.

-- Renombrar el grupo: solo quien lo creó, mismo criterio simple ya usado
-- para "quién puede terminar un directo" (0056_live_streams.sql) -- ampliar
-- a "cualquier miembro puede renombrar" es un cambio de producto real, no
-- una suposición de esta migración.
create policy group_chats_update_own on group_chats
    for update
    using (created_by = (select auth.uid()))
    with check (created_by = (select auth.uid()));

-- El creador se añade a sí mismo como miembro real al crear el grupo --
-- sin esto, la propia política de group_chats_select le impediría ver el
-- grupo que acaba de crear hasta que otro miembro lo añadiera, algo que
-- nunca podría pasar (nadie más es miembro todavía).
create or replace function private.add_group_creator_as_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.group_chat_members (group_chat_id, user_id) values (new.id, new.created_by);
  return new;
end;
$$;

drop trigger if exists trg_add_group_creator_as_member on group_chats;
create trigger trg_add_group_creator_as_member
  after insert on group_chats
  for each row execute function private.add_group_creator_as_member();

-- Mismo criterio que story_views_select_own_story adaptado a un grupo: un
-- miembro ve el resto del grupo A TRAVÉS de su propia pertenencia real
-- (`is_group_member` también es cierto para su propia fila, por
-- reflexividad -- necesario para poder encontrar y borrar su propia fila
-- al salir del grupo, mismo hallazgo real de Postgres/RLS que
-- live_stream_viewers, ver LOOP_STATE.md). `is_group_member` en vez de un
-- `exists` inline por el motivo documentado arriba (recursión real).
create policy group_chat_members_select on group_chat_members
    for select
    using (private.is_group_member(group_chat_members.group_chat_id, (select auth.uid())));

-- Cualquier miembro real puede añadir a otra persona (mismo criterio por
-- defecto que WhatsApp/Messenger, no un flujo de "solo el admin invita"
-- que esta migración no puede justificar sin pedirlo explícitamente) --
-- pero no puede añadir a alguien con quien hay un bloqueo real de por
-- medio, mismo criterio que comment_likes/live_stream_viewers.
create policy group_chat_members_insert on group_chat_members
    for insert
    with check (
        private.is_group_member(group_chat_members.group_chat_id, (select auth.uid()))
        and not private.is_blocked((select auth.uid()), user_id)
    );

create policy group_chat_members_delete_own on group_chat_members
    for delete
    using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- group_messages -- mismo esquema mínimo que messages (0001_schema.sql),
-- sin read receipts/reacciones/voz todavía (hueco real documentado, no
-- fingido -- ver cabecera de esta migración).
-- ---------------------------------------------------------------------------
create table group_messages (
    id uuid primary key default uuid_generate_v4(),
    group_chat_id uuid not null references group_chats(id) on delete cascade,
    sender_id uuid not null references profiles(id) on delete cascade,
    body text check (char_length(body) between 1 and 2000),
    media_url text,
    created_at timestamptz not null default now(),
    check (body is not null or media_url is not null)
);

create index if not exists idx_group_messages_group on group_messages(group_chat_id, created_at);

alter table group_messages enable row level security;

create policy group_messages_select on group_messages
    for select
    using (private.is_group_member(group_messages.group_chat_id, (select auth.uid())));

create policy group_messages_insert on group_messages
    for insert
    with check (
        sender_id = (select auth.uid())
        and private.is_group_member(group_messages.group_chat_id, (select auth.uid()))
    );
