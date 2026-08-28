-- ============================================================================
-- SOCIAL — "Quién visitó tu perfil", comparado con LinkedIn/Twitter-X
-- (Premium)
--
-- Las dos dejan ver quién ha visitado tu perfil recientemente -- SOCIAL ya
-- construyó el mismo patrón real para historias (`story_views`,
-- 0053_story_views.sql, "quién vio tu historia") y reels
-- (`reel_views`, 0131_reel_view_count.sql), pero nunca para el propio
-- perfil. Confirmado con `grep`: no existe `profile_visit` en ningún
-- sitio del repo -- `ProfileViewerScreen.kt`/`ProfileViewerView.swift`
-- (visor de perfil ajeno) cargan el perfil pero no registran nada de la
-- visita.
--
-- Diseño real: `unique(visitor_id, visited_id)` -- a diferencia de
-- story_views/reel_views (contenido efímero/de un solo consumo, cuenta
-- CADA visita nueva como una fila), aquí interesa la visita MÁS RECIENTE
-- (mismo criterio real que LinkedIn: "X visitó tu perfil hace 2h", no un
-- historial de cada apertura) -- upsert con `visited_at` actualizado en
-- cada visita nueva, en vez de acumular una fila por apertura. Solo el
-- visitado puede leer su propia lista (mismo criterio real que
-- story_views_select_own_story: ni siquiera el visitante ve que ya
-- visitó). Autovisitas excluidas (`visitor_id <> visited_id`).
-- ============================================================================

create table profile_visits (
    id uuid primary key default uuid_generate_v4(),
    visitor_id uuid not null references profiles(id) on delete cascade,
    visited_id uuid not null references profiles(id) on delete cascade,
    visited_at timestamptz not null default now(),
    unique (visitor_id, visited_id),
    check (visitor_id <> visited_id)
);

create index if not exists idx_profile_visits_visited on profile_visits(visited_id, visited_at desc);

alter table profile_visits enable row level security;

-- El propio visitante también puede ver su fila (necesario para que el
-- upsert de más abajo funcione: ON CONFLICT DO UPDATE necesita ver la
-- fila existente para decidir que hay conflicto, y sin esto el propio
-- autor de la visita no tenía ningún permiso SELECT real sobre ella,
-- hallazgo real encontrado ejecutando el test de esta misma migración --
-- Postgres devolvía "new row violates row-level security policy" en vez
-- de actualizar visited_at). No hay UI real que muestre "a quién
-- visitaste" con este permiso -- solo hace posible el upsert.
create policy profile_visits_select_own on profile_visits
    for select
    using (visited_id = (select auth.uid()) or visitor_id = (select auth.uid()));

create policy profile_visits_insert_own on profile_visits
    for insert
    with check (visitor_id = (select auth.uid()));

-- Upsert real (visitar el mismo perfil otra vez actualiza visited_at en
-- vez de duplicar fila) -- mismo criterio que saved_posts_update_own
-- (0125): el propio visitante solo puede tocar su propia fila.
create policy profile_visits_update_own on profile_visits
    for update
    using (visitor_id = (select auth.uid()))
    with check (visitor_id = (select auth.uid()));
