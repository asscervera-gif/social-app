-- ============================================================================
-- SOCIAL — Destacados de historias reales en el perfil, comparado con
-- Instagram
--
-- Instagram real deja fijar historias concretas a un "Destacado" con su
-- propio título y portada, mostrado siempre en el perfil -- NUNCA caduca
-- a las 24h, a diferencia de una historia normal. Confirmado en el
-- propio código: `stories_select` (0075_close_friends_stories.sql) exige
-- `expires_at > now()` para CUALQUIERA, así que una historia caducada
-- deja de ser visible para el resto de gente -- SOCIAL no tenía ningún
-- concepto real de "guardar una historia para siempre" en el perfil.
--
-- Diseño real: `story_highlights` (el destacado en sí, con título y
-- portada) + `story_highlight_items` (qué historias reales contiene --
-- referencia a `stories`, nunca una copia). Una vez una historia entra
-- en un destacado, `stories_select` (más abajo) deja de exigirle
-- `expires_at > now()` a ESA fila en concreto -- mismo criterio real de
-- "una excepción se resuelve añadiendo un OR nuevo", sin tocar el resto
-- de reglas de visibilidad ya existentes (mejores amigos sigue exigiendo
-- lo mismo de siempre, incluso dentro de un destacado).
--
-- Aviso de honestidad, aprendido depurando esta misma migración: la
-- primera versión de este comentario afirmaba que "ni siquiera el
-- propio autor ve su historia después de caducar" -- confirmado FALSO
-- con una reproducción aislada. `stories_write_own` (0002_rls.sql) es
-- `for all using (author_id = auth.uid())`, y una política "for all" se
-- combina con OR sobre CUALQUIER operación, incluido el propio SELECT
-- (mismo mecanismo real ya documentado varias veces esta sesión: varias
-- políticas permisivas sobre la misma operación se combinan con OR a
-- nivel de fila) -- el propio autor SIEMPRE ha podido ver (y por tanto
-- destacar) su propia historia, esté caducada o no, desde 0002, sin que
-- ningún cliente hubiera construido nunca esa consulta. Esta migración
-- no crea ningún "archivo" nuevo: ya existía de forma implícita en el
-- backend, esta es la primera vez que se usa de verdad. Por eso el
-- INSERT de `story_highlight_items` de más abajo SÍ deja destacar una
-- historia YA caducada de un tirón (no hace falta ninguna excepción
-- nueva para permitirlo -- ya funcionaba).
-- ============================================================================

create table story_highlights (
    id uuid primary key default uuid_generate_v4(),
    author_id uuid not null references profiles(id) on delete cascade,
    title text not null check (char_length(title) between 1 and 50),
    cover_story_id uuid references stories(id) on delete set null,
    created_at timestamptz not null default now()
);

alter table story_highlights enable row level security;

-- Visible siempre a nivel básico (título, portada), mismo criterio real
-- que profiles_select_public (0002_rls.sql) -- el contenido real de
-- cada historia dentro sigue su propia regla de stories_select de más
-- abajo, así que esto no filtra nada sensible por sí solo.
create policy story_highlights_select on story_highlights
    for select
    using (true);

create policy story_highlights_write_own on story_highlights
    for all
    using (author_id = (select auth.uid()))
    with check (author_id = (select auth.uid()));

create table story_highlight_items (
    id uuid primary key default uuid_generate_v4(),
    highlight_id uuid not null references story_highlights(id) on delete cascade,
    story_id uuid not null references stories(id) on delete cascade,
    added_at timestamptz not null default now(),
    unique (highlight_id, story_id)
);

alter table story_highlight_items enable row level security;

create policy story_highlight_items_select on story_highlight_items
    for select
    using (true);

-- Propiedad doble real: hace falta ser dueño real del destacado Y de la
-- historia que se añade (nunca la de otra persona), mismo criterio ya
-- aplicado esta sesión en otras tablas puente.
create policy story_highlight_items_insert_own on story_highlight_items
    for insert
    with check (
        exists (
            select 1 from story_highlights
            where story_highlights.id = story_highlight_items.highlight_id
              and story_highlights.author_id = (select auth.uid())
        )
        and exists (
            select 1 from stories
            where stories.id = story_highlight_items.story_id
              and stories.author_id = (select auth.uid())
        )
    );

create policy story_highlight_items_delete_own on story_highlight_items
    for delete
    using (
        exists (
            select 1 from story_highlights
            where story_highlights.id = story_highlight_items.highlight_id
              and story_highlights.author_id = (select auth.uid())
        )
    );

drop policy if exists stories_select on stories;
create policy stories_select on stories
    for select
    using (
        (
            expires_at > now()
            or exists (
                select 1 from story_highlight_items
                where story_highlight_items.story_id = stories.id
            )
        )
        and (
            visibility = 'everyone'
            or author_id = (select auth.uid())
            or private.is_close_friend(author_id, (select auth.uid()))
        )
    );
