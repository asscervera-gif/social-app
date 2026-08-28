-- ============================================================================
-- SOCIAL — Sticker de enlace real ("swipe up") en Historias, comparado
-- con Instagram Stories (disponible para todos desde 2021)/TikTok/
-- Snapchat
--
-- `stories` (0001_schema.sql) ya tiene texto (`caption`, 0143), pregunta
-- (0099), encuesta (0100) y compartir post (0129), pero ningún campo de
-- URL externa -- confirmado con grep de "story.*link|link_sticker|
-- swipe.*up" sin resultados en todo el repo, ni tampoco ninguna tabla de
-- clics tipo `story_link_clicks`.
--
-- `story_link_clicks` sigue exactamente el mismo patrón real ya
-- construido y verificado en `story_views` (0053): solo el AUTOR real de
-- la historia puede ver quién hizo clic (mismo criterio real que "quién
-- vio tu historia"), `unique(story_id, user_id)` evita contar dos veces
-- al mismo clic repetido. Sin trigger de contador cacheado -- mismo
-- criterio ya aplicado en `post_reposts` (0127): un `count(*)` real
-- sobre `story_link_clicks` bajo demanda desde el cliente (protegido por
-- la propia RLS solo-autor de abajo) es suficiente, sin necesitar
-- mantener una columna cacheada aparte ni una función RPC nueva.
-- ============================================================================

alter table stories add column link_url text
    check (link_url is null or (char_length(link_url) <= 500 and link_url ~ '^https?://'));

create table story_link_clicks (
    id uuid primary key default uuid_generate_v4(),
    story_id uuid not null references stories(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (story_id, user_id)
);

create index idx_story_link_clicks_story on story_link_clicks(story_id);

alter table story_link_clicks enable row level security;

create policy story_link_clicks_select_own_story on story_link_clicks
    for select
    using (
        exists (
            select 1 from stories
            where stories.id = story_link_clicks.story_id
              and stories.author_id = (select auth.uid())
        )
    );

-- Mismo criterio de apertura que `stories_select`/`story_views_insert_own`
-- (0002/0053): quien puede ver la historia puede registrar que tocó el
-- enlace.
create policy story_link_clicks_insert_own on story_link_clicks
    for insert
    with check (user_id = (select auth.uid()));
