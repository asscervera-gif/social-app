-- ============================================================================
-- SOCIAL — Silenciar las historias de alguien sin dejar de seguirlo,
-- comparado con Instagram/Snapchat
--
-- Las dos dejan silenciar la historia de una persona concreta -- deja de
-- aparecer priorizada en la barra (se manda al final, atenuada) sin
-- desseguir ni bloquear a nadie, y sigue siendo accesible si se busca a
-- propósito. Confirmado en el propio código: `stories_select`
-- (0075_close_friends_stories.sql) solo conoce 'everyone'/'close_friends';
-- `grep` de "muted_story"/"story_mute" en todo el repo no encontró nada.
--
-- Diseño real, distinto de `muted_keywords` (0078) y de `close_friends`
-- (0075): esto NO es un control de acceso (nadie deja de poder ver una
-- historia por esto) ni una regla que dependa del contenido -- es una
-- preferencia personal de ORDEN/visibilidad en la propia bandeja de quien
-- silencia, exactamente como el mute real de Instagram/Snapchat. Por eso
-- NO toca `stories_select`: la fila sigue siendo tan accesible como
-- siempre, la propia app cliente decide cómo ordenarla/atenuarla.
--
-- Mismo criterio de privacidad que `close_friends`: ni siquiera la persona
-- silenciada puede saber que lo está -- solo el propio dueño de la lista
-- puede leerla.
-- ============================================================================

create table muted_story_authors (
    muter_id uuid not null references profiles(id) on delete cascade,
    muted_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (muter_id, muted_id),
    check (muter_id <> muted_id)
);

alter table muted_story_authors enable row level security;

create policy muted_story_authors_select on muted_story_authors
    for select
    using (muter_id = (select auth.uid()));

create policy muted_story_authors_insert on muted_story_authors
    for insert
    with check (muter_id = (select auth.uid()));

create policy muted_story_authors_delete on muted_story_authors
    for delete
    using (muter_id = (select auth.uid()));
