-- ============================================================================
-- SOCIAL — Seguir un hashtag real, comparado con Instagram/TikTok/X
--
-- Confirmado que se puede buscar y ver los resultados de un hashtag
-- (`SearchViewModel.kt.searchHashtag()`, `search_hashtag/{tag}` en
-- RootTabView.kt, `MentionHashtagText.kt` que hace los hashtags
-- pulsables) pero no hay ninguna forma de SEGUIRLO -- grep de
-- "hashtag_follow|follow_hashtag" sobre supabase/migrations/*.sql no
-- devuelve nada. Instagram/TikTok/X dejan seguir un hashtag/tema para
-- no tener que volver a buscarlo cada vez.
--
-- Diseño real: `hashtag` se guarda tal cual (normalizado a minúsculas,
-- sin `#`), no una tabla de hashtags "canónicos" con id propio -- mismo
-- criterio ya usado por la búsqueda real (`ilike("caption", "%#tag%")`),
-- que tampoco necesita una tabla de hashtags para funcionar. Alcance
-- deliberadamente acotado: solo la relación seguir/dejar de seguir y el
-- listado de "hashtags que sigues" -- un feed dedicado que mezcle posts
-- de hashtags seguidos queda fuera de esta ronda (round futura,
-- documentado como tal, no fingido aquí).
-- ============================================================================

create table hashtag_follows (
    user_id uuid not null references profiles(id) on delete cascade,
    hashtag text not null check (hashtag = lower(hashtag) and hashtag !~ '[#\s]'),
    created_at timestamptz not null default now(),
    primary key (user_id, hashtag)
);

alter table hashtag_follows enable row level security;

create index idx_hashtag_follows_hashtag on hashtag_follows(hashtag);

-- Cada quien gestiona solo su propia lista -- mismo criterio que
-- `recent_searches`/`muted_story_authors`, sin necesitar que nadie más
-- vea a quién sigues (a diferencia de `follows`, que sí es pública).
create policy hashtag_follows_own on hashtag_follows
    for all
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));
