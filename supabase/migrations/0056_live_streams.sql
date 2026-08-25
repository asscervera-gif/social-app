-- ============================================================================
-- SOCIAL — Directo (streaming en vivo), comparado con Instagram/TikTok
-- Live: el último hueco grande identificado leyendo SOCIAL_APP.html sin
-- resolver. Bloqueado hasta ahora en decidir un motor real -- el usuario
-- eligió LiveKit Cloud (WebRTC, SDKs Android/iOS/servidor open-source
-- Apache 2.0, cuenta gratuita hasta cierto uso) en vez de self-hosted, para
-- no añadir infraestructura propia que mantener sobre un proyecto ya
-- grande. Pendiente real de DESPLIEGUE (no de código, mismo criterio que
-- push/APNs-FCM en 0043/0044): un proyecto LiveKit Cloud real con
-- LIVEKIT_API_KEY/LIVEKIT_API_SECRET/LIVEKIT_WS_URL, sin los cuales esta
-- pieza compila y corre pero no conecta a ningún servidor real.
--
-- Esta migración es la RONDA DE BACKEND (mismo orden que Reels:
-- 0050_reels.sql primero, cliente después) -- tabla real, RLS real,
-- contador de espectadores real con protección de manipulación, listo
-- para que la siguiente ronda conecte el SDK de LiveKit en ambas
-- plataformas usando esto como fuente de verdad de qué directos existen y
-- quién puede unirse a cuál.
-- ============================================================================

create table live_streams (
    id uuid primary key default uuid_generate_v4(),
    host_id uuid not null references profiles(id) on delete cascade,
    title text,
    -- Nombre de sala real de LiveKit, no reutiliza el uuid de la fila a
    -- propósito: permite rotar el nombre de sala sin tocar la clave
    -- primaria si algún día hiciera falta (p.ej. reintentos tras un fallo
    -- de conexión al mismo directo).
    room_name text not null unique default ('social-' || uuid_generate_v4()::text),
    -- Mismo criterio que posts/reels: visible a todo el mundo salvo que el
    -- propio host lo restrinja a sus socials aceptados.
    is_social_only boolean not null default false,
    status text not null default 'live' check (status in ('live', 'ended')),
    viewer_count integer not null default 0,
    started_at timestamptz not null default now(),
    ended_at timestamptz,
    check (char_length(coalesce(title, '')) <= 140)
);

create index if not exists idx_live_streams_status on live_streams(status, started_at desc);

alter table live_streams enable row level security;

-- Mismo criterio de visibilidad que posts_select/reels_select.
create policy live_streams_select on live_streams
    for select
    using (
        host_id = (select auth.uid())
        or is_social_only = false
        or private.has_accepted_social((select auth.uid()), host_id)
    );

create policy live_streams_insert_own on live_streams
    for insert
    with check (host_id = (select auth.uid()));

-- Para que el host pueda cerrar su propio directo (status='ended',
-- ended_at) y editar el título mientras emite -- viewer_count queda
-- protegido aparte por el trigger de más abajo, igual que
-- protect_reel_counts en 0050_reels.sql.
create policy live_streams_update_own on live_streams
    for update
    using (host_id = (select auth.uid()))
    with check (host_id = (select auth.uid()));

create or replace function private.protect_live_stream_viewer_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if pg_trigger_depth() <= 1 then
        new.viewer_count := old.viewer_count;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_live_stream_viewer_count() from public, anon, authenticated;

drop trigger if exists trg_protect_live_stream_viewer_count on live_streams;
create trigger trg_protect_live_stream_viewer_count
    before update on live_streams
    for each row
    execute function private.protect_live_stream_viewer_count();

-- ---------------------------------------------------------------------------
-- live_stream_viewers — a diferencia de story_views (que registra CADA
-- vista para siempre, "quién la vio"), aquí solo importa quién está
-- viendo AHORA MISMO: una fila = un espectador conectado ahora mismo, se
-- borra de verdad al salir del directo (no un flag `left_at`). El
-- bloqueo se comprueba desde el principio contra el HOST, mismo criterio
-- que comment_likes/reel_likes (0012/0054): unirse a un directo es una
-- interacción sobre el contenido de otra persona.
-- ---------------------------------------------------------------------------
create table live_stream_viewers (
    id uuid primary key default uuid_generate_v4(),
    stream_id uuid not null references live_streams(id) on delete cascade,
    viewer_id uuid not null references profiles(id) on delete cascade,
    joined_at timestamptz not null default now(),
    unique (stream_id, viewer_id)
);

create index if not exists idx_live_stream_viewers_stream on live_stream_viewers(stream_id);

alter table live_stream_viewers enable row level security;

-- Mismo criterio que story_views_select_own_story: solo el HOST ve la
-- LISTA COMPLETA de quién está viendo -- ni siquiera un espectador ve las
-- filas de los demás. Pero a diferencia de story_views (que nunca se
-- borra, es historial), aquí cada espectador necesita poder encontrar y
-- borrar SU PROPIA fila al salir del directo -- y en Postgres, DELETE (y
-- UPDATE) solo pueden operar sobre filas que la propia fila también deje
-- ver por SELECT (la política de DELETE no basta por sí sola para que la
-- fila sea "candidata"). Sin este `viewer_id = auth.uid()` aquí, ningún
-- espectador podría salir nunca de un directo -- real, no hipotético:
-- descubierto por el propio arnés de pruebas (ver test_rls.mjs).
create policy live_stream_viewers_select_own_stream on live_stream_viewers
    for select
    using (
        viewer_id = (select auth.uid())
        or exists (
            select 1 from live_streams
            where live_streams.id = live_stream_viewers.stream_id
              and live_streams.host_id = (select auth.uid())
        )
    );

create policy live_stream_viewers_insert_own on live_stream_viewers
    for insert
    with check (
        viewer_id = (select auth.uid())
        and not private.is_blocked(
            viewer_id,
            (select host_id from live_streams where live_streams.id = live_stream_viewers.stream_id)
        )
    );

create policy live_stream_viewers_delete_own on live_stream_viewers
    for delete
    using (viewer_id = (select auth.uid()));

create or replace function private.sync_live_stream_viewer_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    update public.live_streams set viewer_count = viewer_count + 1 where id = new.stream_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update public.live_streams set viewer_count = greatest(0, viewer_count - 1) where id = old.stream_id;
    return old;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_sync_live_stream_viewer_count on live_stream_viewers;
create trigger trg_sync_live_stream_viewer_count
  after insert or delete on live_stream_viewers
  for each row execute function private.sync_live_stream_viewer_count();
