-- ============================================================================
-- SOCIAL — Panel de estadísticas del post ("Insights") para el autor,
-- comparado con Instagram ("Ver estadísticas")/TikTok (Analytics)/Facebook
--
-- Confirmado que no existe ninguna pantalla ni función de analíticas de
-- publicaciones: grep de "AnalyticsScreen|InsightsScreen|post_insights|
-- reach_count|impressions" sobre supabase/migrations/*.sql y ambos
-- clientes no devuelve nada. `posts` ya tiene `like_count`/`comment_count`
-- (mantenidos por trigger desde 0007/0008), pero nunca se contaba cuánta
-- gente REAL vio la publicación (alcance) ni cuánta la guardó -- ambos
-- datos sí existen ya en `saved_posts` (fila por guardado), pero nadie
-- los agregaba para el autor.
--
-- `post_views` sigue exactamente el mismo patrón real ya construido y
-- verificado en 0131_reel_view_count.sql (Round 74 de esta sesión): una
-- tabla hija con `unique(post_id, viewer_id)` cuyo propio trigger AFTER
-- INSERT actualiza `posts.view_count`, anidado DENTRO de otro trigger
-- (profundidad 2), para poder rodear la guardia
-- `pg_trigger_depth() <= 1` de `protect_post_counts()` (0033) sin tener
-- que reescribir esa función con una excepción por `current_user` --
-- lección real ya aprendida en esta sesión: en el arnés local (PGlite),
-- `current_user` dentro de una función SECURITY DEFINER es siempre el
-- OWNER de la función, nunca el rol de quien llama, así que una
-- excepción por `current_user = 'postgres'` rompería la protección real
-- para cualquier llamada -- el patrón de profundidad anidada es el único
-- correcto aquí.
-- ============================================================================

alter table posts add column view_count integer not null default 0;

create table post_views (
    id uuid primary key default uuid_generate_v4(),
    post_id uuid not null references posts(id) on delete cascade,
    viewer_id uuid not null references profiles(id) on delete cascade,
    viewed_at timestamptz not null default now(),
    unique (post_id, viewer_id)
);

alter table post_views enable row level security;

create index idx_post_views_post_id on post_views(post_id);

-- Solo insertar la propia vista real -- nadie necesita ver quién vio en
-- detalle todavía (a diferencia de story_views/reel_views, que sí
-- exponen el listado a quien tiene la story activa); esta ronda solo
-- necesita el CONTEO agregado, expuesto vía get_post_insights() más
-- abajo con su propio control de acceso (solo el autor real).
create policy post_views_insert_own on post_views
    for insert
    with check (viewer_id = (select auth.uid()));

create or replace function private.sync_post_view_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.posts set view_count = view_count + 1 where id = new.post_id;
    return new;
end;
$$;

revoke execute on function private.sync_post_view_count() from public, anon, authenticated;

drop trigger if exists trg_sync_post_view_count on post_views;
create trigger trg_sync_post_view_count
    after insert on post_views
    for each row
    execute function private.sync_post_view_count();

-- protect_post_counts (0033) ampliada para cubrir también view_count --
-- mismo criterio exacto: el autor no debe poder escribir su propio
-- alcance a mano, la fuente de verdad es post_views.
create or replace function private.protect_post_counts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if pg_trigger_depth() <= 1 then
        new.like_count := old.like_count;
        new.comment_count := old.comment_count;
        new.view_count := old.view_count;
    end if;
    return new;
end;
$$;

-- Panel de estadísticas real: alcance, me gusta, comentarios y guardados
-- -- solo accesible al autor real del post (comprobado dentro de la
-- propia función, no delegado a RLS). security definer porque agrega
-- sobre saved_posts, cuya RLS (saved_posts_select_own) no dejaría ver
-- filas ajenas ni siquiera al autor del post guardado.
create or replace function public.get_post_insights(p_post_id uuid)
returns table (
    view_count integer,
    like_count integer,
    comment_count integer,
    saved_count bigint
)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
    if not exists (select 1 from public.posts where id = p_post_id and author_id = (select auth.uid())) then
        raise exception 'Solo el autor real puede ver las estadísticas de esta publicación.';
    end if;
    return query
    select p.view_count, p.like_count, p.comment_count,
           (select count(*) from public.saved_posts sp where sp.post_id = p_post_id)
    from public.posts p
    where p.id = p_post_id;
end;
$$;

revoke all on function public.get_post_insights(uuid) from public;
grant execute on function public.get_post_insights(uuid) to authenticated;
