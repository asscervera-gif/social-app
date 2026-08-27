-- ============================================================================
-- SOCIAL — Encuesta real en una historia, comparado con Instagram/Twitter/X
-- Twitter/X (encuestas nativas en un tuit) e Instagram (adhesivo de
-- encuesta en historias) dejan las dos publicar una pregunta con 2-4
-- opciones reales y ver el reparto en vivo (barras de porcentaje) --
-- distinto del adhesivo de pregunta de 0099_story_questions.sql (texto
-- libre y privado, sin agregación real): aquí el voto es una elección
-- entre opciones fijas, y el REPARTO (no la identidad de quién votó qué)
-- es público para cualquiera que vea la historia, igual que en esas apps.
--
-- Diseño real: `story_polls` (la encuesta en sí, con sus opciones reales
-- en un array) + `story_poll_votes` (cada voto real, uno por persona,
-- `unique(poll_id, voter_id)` -- cambiar de opción es un UPDATE de la
-- fila propia, no un segundo voto). Mismo reparto de visibilidad real
-- que el "quién vio tu historia" (0053) frente al "veo el reparto pero
-- no quién votó qué" de esas apps: el AUTOR real de la historia sí ve
-- cada voto individual (con quién lo emitió, igual que Instagram real
-- deja tocar una encuesta propia para ver el desglose por persona); el
-- resto de espectadores reales NUNCA ve la fila de otro, solo el
-- reparto agregado.
--
-- `story_polls.vote_counts` (recuento por opción, sin `voter_id`) es lo
-- que cualquier espectador real necesita para pintar las barras de
-- porcentaje -- mismo patrón exacto que `posts.like_count`
-- (sync_post_like_count, 0004/0008): un trigger real recalcula el
-- agregado en cuanto cambia `story_poll_votes`, nunca el propio cliente.
-- Aviso de honestidad, aprendido depurando esta misma migración: la
-- primera versión exponía el reparto agregado como una función normal
-- de PL/pgSQL en el esquema `private`, pensada para llamarse
-- directamente desde el cliente (`.rpc(...)`) -- pero `private` es a
-- propósito un esquema INTERNO, nunca expuesto a PostgREST ni con
-- `USAGE` real concedido a `authenticated` (a diferencia de `public`,
-- confirmado con una reproducción aislada: la propia llamada fallaba
-- con "permission denied for schema private" antes incluso de ejecutar
-- una sola línea de la función) -- todas las demás funciones de
-- `private.*` de esta sesión solo se llaman desde DENTRO de una
-- política RLS o un trigger ya creados por el superusuario (que
-- resuelve esa referencia con sus propios privilegios), nunca como
-- destino directo de una llamada real del cliente. Una columna normal
-- en `public.story_polls`, cubierta por la política de SELECT ya
-- existente, evita el problema de raíz.
-- ============================================================================

create table story_polls (
    id uuid primary key default uuid_generate_v4(),
    story_id uuid not null references stories(id) on delete cascade,
    question text not null check (char_length(question) between 1 and 200),
    -- Array real de 2 a 4 opciones de texto, mismo límite real que
    -- Instagram/Twitter/X (mínimo 2 para que tenga sentido elegir,
    -- máximo 4 porque ninguna de las dos apps de referencia permite más).
    options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 4),
    -- Recuento real por opción (mismo orden que `options`), mantenido
    -- solo por el trigger de más abajo -- sin política de UPDATE real
    -- para nadie más, ni siquiera el propio autor (`story_polls` no
    -- tiene ninguna política "for all"/update, a diferencia de
    -- `posts_write_own`), así que no hace falta un trigger de
    -- protección aparte: RLS ya impide cualquier UPDATE directo de
    -- un usuario normal.
    vote_counts jsonb not null default '[]'::jsonb,
    created_at timestamptz not null default now()
);

alter table story_polls enable row level security;

create policy story_polls_select on story_polls
    for select
    using (
        exists (
            select 1 from stories
            where stories.id = story_polls.story_id
              and stories.expires_at > now()
              and (
                  stories.visibility = 'everyone'
                  or stories.author_id = (select auth.uid())
                  or private.is_close_friend(stories.author_id, (select auth.uid()))
              )
        )
    );

create policy story_polls_insert_own on story_polls
    for insert
    with check (
        exists (
            select 1 from stories
            where stories.id = story_polls.story_id
              and stories.author_id = (select auth.uid())
        )
    );

create policy story_polls_delete_own on story_polls
    for delete
    using (
        exists (
            select 1 from stories
            where stories.id = story_polls.story_id
              and stories.author_id = (select auth.uid())
        )
    );

create table story_poll_votes (
    id uuid primary key default uuid_generate_v4(),
    poll_id uuid not null references story_polls(id) on delete cascade,
    voter_id uuid not null references profiles(id) on delete cascade,
    option_index integer not null check (option_index >= 0),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (poll_id, voter_id)
);

alter table story_poll_votes enable row level security;

-- Privada a nivel de fila individual: el propio votante ve su voto, y el
-- autor real de la historia ve TODOS los votos de su propia encuesta con
-- quién los emitió (igual que Instagram real) -- cualquier otro
-- espectador real NUNCA ve la fila de otra persona (usa
-- private.story_poll_counts() para el reparto agregado, más abajo).
create policy story_poll_votes_select on story_poll_votes
    for select
    using (
        voter_id = (select auth.uid())
        or exists (
            select 1 from story_polls
            join stories on stories.id = story_polls.story_id
            where story_polls.id = story_poll_votes.poll_id
              and stories.author_id = (select auth.uid())
        )
    );

create policy story_poll_votes_insert_own on story_poll_votes
    for insert
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from story_polls
            join stories on stories.id = story_polls.story_id
            where story_polls.id = story_poll_votes.poll_id
              and story_poll_votes.option_index < jsonb_array_length(story_polls.options)
              and stories.expires_at > now()
              and (
                  stories.visibility = 'everyone'
                  or stories.author_id = (select auth.uid())
                  or private.is_close_friend(stories.author_id, (select auth.uid()))
              )
              and not private.is_blocked(story_poll_votes.voter_id, stories.author_id)
        )
    );

-- Cambiar de opción real, comparado con Instagram/Twitter/X (las dos
-- dejan votar de nuevo antes de que acabe la historia/el tuit) -- mismo
-- límite real de opciones válidas que el INSERT, y solo la propia fila.
create policy story_poll_votes_update_own on story_poll_votes
    for update
    using (voter_id = (select auth.uid()))
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from story_polls
            where story_polls.id = story_poll_votes.poll_id
              and story_poll_votes.option_index < jsonb_array_length(story_polls.options)
        )
    );

-- Recalcula `story_polls.vote_counts` real cada vez que cambia un voto
-- -- mismo patrón exacto que sync_post_like_count (0004/0008).
-- `generate_series` rellena con 0 las opciones sin ningún voto todavía
-- (sin esto, un array corto perdería la correspondencia posicional real
-- con `options` en cuanto una opción se quedara sin votos).
create or replace function private.sync_story_poll_counts()
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
  from public.story_polls where id = v_poll_id;

  update public.story_polls
  set vote_counts = (
    select coalesce(jsonb_agg(coalesce(counted.votes, 0) order by idx.option_index), '[]'::jsonb)
    from generate_series(0, v_option_count - 1) as idx(option_index)
    left join (
      select option_index, count(*) as votes
      from public.story_poll_votes
      where poll_id = v_poll_id
      group by option_index
    ) counted on counted.option_index = idx.option_index
  )
  where id = v_poll_id;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_story_poll_counts on story_poll_votes;
create trigger trg_sync_story_poll_counts
  after insert or update or delete on story_poll_votes
  for each row execute function private.sync_story_poll_counts();
