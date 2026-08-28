-- ============================================================================
-- SOCIAL — Encuesta real dentro de un chat de GRUPO, comparado con
-- WhatsApp (Encuestas en chats de grupo, función insignia desde 2023)
--
-- WhatsApp deja crear una encuesta real como tipo de mensaje dentro de un
-- chat de grupo -- pregunta + varias opciones, cada miembro vota, se ve
-- el reparto en vivo. Confirmado en el propio código: `group_messages`
-- (0057_group_chats.sql, líneas 163-171) solo admite `body` (texto) o
-- `media_url` (foto/vídeo), sin ningún concepto de encuesta -- grep de
-- "poll" en GroupChatViewModel.kt/.swift sin resultados. SOCIAL ya
-- construyó el mecanismo de encuesta DOS veces -- para historias
-- (0100_story_polls.sql) y para publicaciones (0113_post_polls.sql),
-- mismo patrón `*_polls` (pregunta+opciones+vote_counts) + `*_poll_votes`
-- (un voto por persona, cambiar de opción = UPDATE) -- pero nunca para un
-- mensaje de chat, justo donde WhatsApp lo usa más (organizar un plan,
-- votar una fecha).
--
-- Mismo diseño EXACTO que 0113_post_polls.sql, adaptado a un mensaje de
-- grupo en vez de una publicación: `group_message_polls` (referencia a
-- `group_messages`) + `group_message_poll_votes`. Visibilidad = ser
-- miembro real del grupo (`private.is_group_member`, mismo helper ya
-- usado en `group_messages_select`) -- a diferencia de post_polls (autor
-- ve cada voto, resto solo agregado), aquí CUALQUIER miembro ve cada
-- voto individual de cualquier otro miembro (mismo criterio real que
-- WhatsApp: en un grupo, votar una encuesta es visible para todos los
-- miembros, no solo para quien la creó -- coordinar un plan requiere
-- saber quién votó qué, no solo el reparto).
--
-- `group_messages.body` se rellena con la pregunta real de la encuesta
-- al enviarla (no queda null) -- evita tocar la restricción real
-- `check (body is not null or media_url is not null)` (0057), mismo
-- criterio de "reutilizar antes que reinventar" ya aplicado varias veces
-- esta sesión. Alcance deliberado: solo chat de GRUPO, no 1:1 -- el caso
-- de uso real de WhatsApp (coordinar un grupo) es donde compite
-- directamente.
-- ============================================================================

create table group_message_polls (
    id uuid primary key default uuid_generate_v4(),
    group_message_id uuid not null references group_messages(id) on delete cascade,
    question text not null check (char_length(question) between 1 and 200),
    options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 8),
    vote_counts jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);

alter table group_message_polls enable row level security;

create policy group_message_polls_select on group_message_polls
    for select
    using (
        exists (
            select 1 from group_messages
            where group_messages.id = group_message_polls.group_message_id
              and private.is_group_member(group_messages.group_chat_id, (select auth.uid()))
        )
    );

create policy group_message_polls_insert_own on group_message_polls
    for insert
    with check (
        exists (
            select 1 from group_messages
            where group_messages.id = group_message_polls.group_message_id
              and group_messages.sender_id = (select auth.uid())
        )
    );

create table group_message_poll_votes (
    id uuid primary key default uuid_generate_v4(),
    poll_id uuid not null references group_message_polls(id) on delete cascade,
    voter_id uuid not null references profiles(id) on delete cascade,
    option_index integer not null check (option_index >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (poll_id, voter_id)
);

alter table group_message_poll_votes enable row level security;

-- Cualquier miembro real del grupo ve cada voto individual, no solo el
-- reparto agregado -- criterio deliberadamente distinto de post_polls,
-- ver comentario de cabecera.
create policy group_message_poll_votes_select on group_message_poll_votes
    for select
    using (
        exists (
            select 1 from group_message_polls
            join group_messages on group_messages.id = group_message_polls.group_message_id
            where group_message_polls.id = group_message_poll_votes.poll_id
              and private.is_group_member(group_messages.group_chat_id, (select auth.uid()))
        )
    );

create policy group_message_poll_votes_insert_own on group_message_poll_votes
    for insert
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from group_message_polls
            join group_messages on group_messages.id = group_message_polls.group_message_id
            where group_message_polls.id = group_message_poll_votes.poll_id
              and group_message_poll_votes.option_index < jsonb_array_length(group_message_polls.options)
              and private.is_group_member(group_messages.group_chat_id, (select auth.uid()))
        )
    );

create policy group_message_poll_votes_update_own on group_message_poll_votes
    for update
    using (voter_id = (select auth.uid()))
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from group_message_polls
            where group_message_polls.id = group_message_poll_votes.poll_id
              and group_message_poll_votes.option_index < jsonb_array_length(group_message_polls.options)
        )
    );

-- Mismo patrón exacto que private.sync_post_poll_counts (0113).
create or replace function private.sync_group_message_poll_counts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_poll_id uuid := coalesce(new.poll_id, old.poll_id);
  v_option_count integer;
begin
  select jsonb_array_length(options) into v_option_count
  from public.group_message_polls where id = v_poll_id;

  update public.group_message_polls
  set vote_counts = (
    select coalesce(jsonb_agg(coalesce(counted.votes, 0) order by idx.option_index), '[]'::jsonb)
    from generate_series(0, v_option_count - 1) as idx(option_index)
    left join (
      select option_index, count(*) as votes
      from public.group_message_poll_votes
      where poll_id = v_poll_id
      group by option_index
    ) counted on counted.option_index = idx.option_index
  )
  where id = v_poll_id;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_group_message_poll_counts on group_message_poll_votes;
create trigger trg_sync_group_message_poll_counts
  after insert or update or delete on group_message_poll_votes
  for each row execute function private.sync_group_message_poll_counts();
