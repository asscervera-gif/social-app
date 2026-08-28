-- ============================================================================
-- SOCIAL — Contador real de vistas en Reels, comparado con TikTok/
-- Instagram Reels
--
-- Hallazgo real, un bug ya existente (no solo un hueco de funcionalidad):
-- `reels.view_count` existe desde 0050_reels.sql y ambos clientes ya lo
-- decodifican/muestran (`ReelsViewModel.kt`/`.swift`), pero confirmado con
-- `grep` en todo `Android/`/`Social/`: NINGÚN sitio del código lo
-- incrementa jamás -- el contador real que se ve en pantalla está muerto,
-- siempre en 0. La razón real: `reels_write_own` (0050) es la ÚNICA
-- política de escritura, `for all` y limitada al propio autor -- un
-- espectador cualquiera nunca podría hacer un UPDATE directo sobre
-- `view_count` aunque el cliente lo intentara.
--
-- Segundo hallazgo real, encontrado escribiendo el test de esta misma
-- migración: la primera versión intentaba resolverlo con una función
-- SECURITY DEFINER que hacía `update reels set view_count = ...`
-- directamente -- pero `protect_reel_counts` (0050) revierte cualquier
-- UPDATE con `pg_trigger_depth() <= 1`, exactamente la profundidad real
-- con la que llega esa sentencia al ejecutarse DIRECTAMENTE dentro de la
-- función (no anidada dentro de OTRO trigger). Añadir una excepción real
-- por `current_user = 'postgres'` pareció la solución (mismo patrón que
-- `purchase_avatar_item`), pero rompió el test YA EXISTENTE de
-- `protect_reel_counts` -- confirmado en el propio arnés de pruebas: aquí
-- `current_user` es SIEMPRE 'postgres' (mismo hallazgo ya documentado en
-- la Ronda 56 con `protect_comment_pin_only`), así que esa guardia habría
-- quedado siempre desactivada para CUALQUIERA, no solo para esta función.
--
-- Solución real correcta: mismo mecanismo YA usado por like_count/
-- comment_count -- una tabla propia (`reel_views`, insertada por el
-- cliente vía RLS normal) con un trigger AFTER INSERT que hace el UPDATE
-- real sobre `reels`. Esa UPDATE se ejecuta ANIDADA dentro del trigger de
-- `reel_views` (pg_trigger_depth() = 2 en ese punto), así que
-- `protect_reel_counts` la deja pasar sin tocar su guardia original en
-- absoluto -- ni falsos positivos ni necesidad de current_user.
-- `unique(reel_id, viewer_id)`, mismo criterio real que likes/reposts/
-- saved_posts: cada espectador cuenta como máximo una vez, no una vez
-- por reproducción repetida. Las vistas del propio autor sobre su propio
-- reel no incrementan el contador real.
-- ============================================================================

create table reel_views (
    id uuid primary key default uuid_generate_v4(),
    reel_id uuid not null references reels(id) on delete cascade,
    viewer_id uuid not null references profiles(id) on delete cascade,
    viewed_at timestamptz not null default now(),
    unique (reel_id, viewer_id)
);

create index if not exists idx_reel_views_reel on reel_views(reel_id);

alter table reel_views enable row level security;

create policy reel_views_insert_own on reel_views
    for insert
    with check (viewer_id = (select auth.uid()));

create or replace function private.sync_reel_view_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.reels where id = new.reel_id;
  if v_author_id is not null and v_author_id <> new.viewer_id then
    update public.reels set view_count = view_count + 1 where id = new.reel_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_reel_view_count on reel_views;
create trigger trg_sync_reel_view_count
  after insert on reel_views
  for each row execute function private.sync_reel_view_count();
