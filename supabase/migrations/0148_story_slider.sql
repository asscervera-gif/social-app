-- ============================================================================
-- SOCIAL — Sticker de emoji deslizante ("slider") en Historias,
-- comparado con Instagram (desde 2018)/Facebook Stories
--
-- `stories` ya tiene texto/mención (0143), pregunta (0099), encuesta
-- (0100), compartir post (0129), enlace (0146) y cuenta atrás (0147),
-- pero ningún sticker de intensidad tipo "desliza el emoji de 0 a 100"
-- -- confirmado con grep de "emoji_slider|slider_sticker" sin
-- resultados en todo el repo.
--
-- Diseño real, mismo patrón exacto que `story_polls`/`story_poll_votes`
-- (0100): `stories.slider_emoji`/`slider_label` son el sticker en sí
-- (una sola por historia, igual que el diseño real de Instagram);
-- `story_slider_responses` es cada respuesta real, `unique(story_id,
-- user_id)` para poder cambiar de opinión (UPDATE) en vez de duplicar.
-- El promedio (`slider_average`/`slider_count`) se mantiene con un
-- trigger real sobre `stories`, NUNCA con una función RPC en el esquema
-- `private` -- lección real ya aprendida y documentada en 0100: ese
-- esquema no tiene `USAGE` concedido a `authenticated`, cualquier
-- llamada directa del cliente falla con "permission denied for schema
-- private" antes de ejecutar una sola línea.
--
-- Privacidad real: igual que las encuestas (0100), el AUTOR de la
-- historia ve cada respuesta individual (con quién la mandó); cualquier
-- otro espectador real solo ve el promedio agregado
-- (`stories.slider_average`), nunca la fila de otra persona.
-- ============================================================================

alter table stories add column slider_emoji text not null default '😍';
alter table stories add column slider_label text check (slider_label is null or char_length(slider_label) <= 60);
alter table stories add column slider_average numeric;
alter table stories add column slider_count integer not null default 0;

create table story_slider_responses (
    id uuid primary key default uuid_generate_v4(),
    story_id uuid not null references stories(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    value smallint not null check (value between 0 and 100),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (story_id, user_id)
);

alter table story_slider_responses enable row level security;

-- Mismo criterio real que story_poll_votes_select: el propio autor de
-- la respuesta ve su fila, el AUTOR de la historia ve todas (con quién
-- respondió); cualquier otro espectador real usa
-- stories.slider_average, nunca esta tabla directamente.
create policy story_slider_responses_select on story_slider_responses
    for select
    using (
        user_id = (select auth.uid())
        or exists (
            select 1 from stories
            where stories.id = story_slider_responses.story_id
              and stories.author_id = (select auth.uid())
        )
    );

create policy story_slider_responses_insert_own on story_slider_responses
    for insert
    with check (
        user_id = (select auth.uid())
        and exists (
            select 1 from stories
            where stories.id = story_slider_responses.story_id
              and stories.expires_at > now()
              and (
                  stories.visibility = 'everyone'
                  or stories.author_id = (select auth.uid())
                  or private.is_close_friend(stories.author_id, (select auth.uid()))
              )
              and not private.is_blocked(story_slider_responses.user_id, stories.author_id)
        )
    );

-- Cambiar de valor real, comparado con Instagram (se puede arrastrar el
-- emoji de nuevo mientras la historia siga activa) -- solo la propia fila.
create policy story_slider_responses_update_own on story_slider_responses
    for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

-- Recalcula stories.slider_average/slider_count real cada vez que
-- cambia una respuesta -- mismo patrón exacto que
-- sync_story_poll_counts (0100).
create or replace function private.sync_story_slider_average()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_story_id uuid := coalesce(new.story_id, old.story_id);
begin
  update public.stories
  set slider_average = (select avg(value) from public.story_slider_responses where story_id = v_story_id),
      slider_count = (select count(*) from public.story_slider_responses where story_id = v_story_id)
  where id = v_story_id;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_sync_story_slider_average on story_slider_responses;
create trigger trg_sync_story_slider_average
  after insert or update or delete on story_slider_responses
  for each row execute function private.sync_story_slider_average();
