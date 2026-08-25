-- ============================================================================
-- SOCIAL — "Quién vio tu historia", comparado con Instagram/Snapchat/
-- WhatsApp Status/Facebook: las cuatro dejan ver la lista de quién ha
-- visto tu propia historia, una de las funciones más usadas de esa parte
-- de la app. `stories` (0001_schema.sql) existe desde el principio, pero
-- nunca hubo ninguna tabla que registrara quién la vio -- el hueco no es
-- de UI solamente, la propia base de datos no guardaba ese dato en
-- absoluto.
--
-- Solo el AUTOR de la historia puede ver la lista de espectadores (mismo
-- criterio que Instagram: ni siquiera el espectador ve una lista de "ya
-- vista por ti"). `unique(story_id, viewer_id)` evita contar una misma
-- persona más de una vez si vuelve a abrir la misma historia.
-- ============================================================================

create table story_views (
    id uuid primary key default uuid_generate_v4(),
    story_id uuid not null references stories(id) on delete cascade,
    viewer_id uuid not null references profiles(id) on delete cascade,
    viewed_at timestamptz not null default now(),
    unique (story_id, viewer_id)
);

create index if not exists idx_story_views_story on story_views(story_id);

alter table story_views enable row level security;

create policy story_views_select_own_story on story_views
    for select
    using (
        exists (
            select 1 from stories
            where stories.id = story_views.story_id
              and stories.author_id = (select auth.uid())
        )
    );

-- Mismo criterio de apertura que `stories_select` (0002_rls.sql, pública
-- para cualquier historia no caducada, sin restricción de social): quien
-- puede ver la historia puede registrar que la vio.
create policy story_views_insert_own on story_views
    for insert
    with check (viewer_id = (select auth.uid()));
