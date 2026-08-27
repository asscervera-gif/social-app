-- ============================================================================
-- SOCIAL — Encuesta real en una publicación normal, comparado con
-- Twitter/X/Facebook
--
-- Twitter/X y Facebook dejan las dos adjuntar una encuesta real (2-4
-- opciones fijas) a una publicación normal del feed, permanente -- NO
-- solo a una historia efímera. `0100_story_polls.sql` ya construyó todo
-- el mecanismo real de encuesta (opciones/votos/reparto agregado) pero
-- SOLO para historias -- confirmado en el propio código: `posts` no
-- tenía ningún concepto de encuesta, y una encuesta en una publicación
-- normal es justo la clase de contenido que SÍ tiene sentido que dure
-- (a diferencia de una pregunta de texto libre o una reacción rápida,
-- ya cerrado esta sesión con el patrón "no hace falta backend nuevo"
-- cuando de verdad no hacía falta -- aquí SÍ hace falta, es un concepto
-- de esquema real distinto).
--
-- Mismo diseño EXACTO que 0100_story_polls.sql, adaptado a `posts` en
-- vez de `stories`: `post_polls` (la encuesta) + `post_poll_votes`
-- (cada voto real, uno por persona, cambiar de opción es un UPDATE de
-- la fila propia). Mismo reparto de visibilidad: el AUTOR real de la
-- publicación ve cada voto individual con quién lo emitió; cualquier
-- otro espectador real solo ve el reparto agregado (`vote_counts`,
-- mismo trigger `AFTER INSERT/UPDATE/DELETE` que ya usa 0100).
--
-- Alcance deliberado, distinto de Twitter/X a propósito: SIN duración
-- elegible (24h/3 días/7 días) -- `posts` no tiene ningún concepto de
-- expiración en absoluto (a diferencia de `stories`), y añadir uno
-- solo para encuestas sería una pieza nueva de UI/estado sin relación
-- con el hallazgo real de esta ronda (falta la encuesta en sí, no su
-- caducidad). Más cerca del modelo de Facebook: la encuesta dura tanto
-- como la propia publicación.
--
-- Visibilidad = misma regla real que `posts_select` (0076): autor,
-- público, o social aceptado si `is_social_only`, y nunca si la
-- publicación está archivada -- ninguna condición nueva que inventar,
-- solo reflejar la misma regla ya establecida.
-- ============================================================================

create table post_polls (
    id uuid primary key default uuid_generate_v4(),
    post_id uuid not null references posts(id) on delete cascade,
    question text not null check (char_length(question) between 1 and 200),
    options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 4),
    vote_counts jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);

alter table post_polls enable row level security;

create policy post_polls_select on post_polls
    for select
    using (
        exists (
            select 1 from posts
            where posts.id = post_polls.post_id
              and (
                  posts.author_id = (select auth.uid())
                  or (
                      posts.archived_at is null
                      and (
                          posts.is_social_only = false
                          or private.has_accepted_social((select auth.uid()), posts.author_id)
                      )
                  )
              )
        )
    );

create policy post_polls_insert_own on post_polls
    for insert
    with check (
        exists (select 1 from posts where posts.id = post_polls.post_id and posts.author_id = (select auth.uid()))
    );

create policy post_polls_delete_own on post_polls
    for delete
    using (
        exists (select 1 from posts where posts.id = post_polls.post_id and posts.author_id = (select auth.uid()))
    );

create table post_poll_votes (
    id uuid primary key default uuid_generate_v4(),
    poll_id uuid not null references post_polls(id) on delete cascade,
    voter_id uuid not null references profiles(id) on delete cascade,
    option_index integer not null check (option_index >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (poll_id, voter_id)
);

alter table post_poll_votes enable row level security;

create policy post_poll_votes_select on post_poll_votes
    for select
    using (
        voter_id = (select auth.uid())
        or exists (
            select 1 from post_polls
            join posts on posts.id = post_polls.post_id
            where post_polls.id = post_poll_votes.poll_id
              and posts.author_id = (select auth.uid())
        )
    );

create policy post_poll_votes_insert_own on post_poll_votes
    for insert
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from post_polls
            join posts on posts.id = post_polls.post_id
            where post_polls.id = post_poll_votes.poll_id
              and post_poll_votes.option_index < jsonb_array_length(post_polls.options)
              and (
                  posts.author_id = (select auth.uid())
                  or (
                      posts.archived_at is null
                      and (
                          posts.is_social_only = false
                          or private.has_accepted_social((select auth.uid()), posts.author_id)
                      )
                  )
              )
              and not private.is_blocked(post_poll_votes.voter_id, posts.author_id)
        )
    );

create policy post_poll_votes_update_own on post_poll_votes
    for update
    using (voter_id = (select auth.uid()))
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from post_polls
            where post_polls.id = post_poll_votes.poll_id
              and post_poll_votes.option_index < jsonb_array_length(post_polls.options)
        )
    );

-- Mismo patrón exacto que private.sync_story_poll_counts (0100).
create or replace function private.sync_post_poll_counts()
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
  from public.post_polls where id = v_poll_id;

  update public.post_polls
  set vote_counts = (
    select coalesce(jsonb_agg(coalesce(counted.votes, 0) order by idx.option_index), '[]'::jsonb)
    from generate_series(0, v_option_count - 1) as idx(option_index)
    left join (
      select option_index, count(*) as votes
      from public.post_poll_votes
      where poll_id = v_poll_id
      group by option_index
    ) counted on counted.option_index = idx.option_index
  )
  where id = v_poll_id;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_post_poll_counts on post_poll_votes;
create trigger trg_sync_post_poll_counts
  after insert or update or delete on post_poll_votes
  for each row execute function private.sync_post_poll_counts();
