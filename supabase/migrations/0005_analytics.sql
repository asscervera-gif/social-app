-- ============================================================================
-- SOCIAL — Analítica mínima, auto-alojada (sin SDKs de terceros de pago)
-- ============================================================================
-- Objetivo deliberadamente acotado: medir la métrica que growth_strategy.md
-- identifica como la que de verdad importa para un producto con umbral
-- físico — densidad efectiva por evento/sesión — no un sistema de tracking
-- genérico de comportamiento. Cada fila es un evento de producto, no datos
-- de ubicación/proximidad (esos nunca salen del dispositivo, ver
-- security_checklist.md).

create table analytics_events (
    id uuid primary key default uuid_generate_v4(),
    profile_id uuid references profiles(id) on delete set null,
    event_type text not null check (event_type in (
        'app_open', 'tab_view', 'social_sent', 'social_accepted',
        'duel_completed', 'event_joined', 'invisible_toggled'
    )),
    event_id uuid references events(id) on delete set null, -- null salvo en eventos de Modo Evento
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

alter table analytics_events enable row level security;

create index idx_analytics_events_type_created on analytics_events(event_type, created_at desc);
create index idx_analytics_events_event on analytics_events(event_id) where event_id is not null;

-- Solo inserción desde el cliente, con su propio profile_id — nunca lectura
-- (los paneles de densidad por evento se consultan con service_role, no
-- desde la app, igual que los reports de seguridad en 0003_safety.sql).
create policy analytics_events_insert_own on analytics_events
    for insert
    with check (profile_id = (select auth.uid()) or profile_id is null);

-- security definer: calcula el % de asistentes de un evento con actividad
-- reciente (Home/Match/Social abierto) — la "densidad efectiva" que
-- growth_strategy.md señala como la métrica de éxito temprano real, en vez
-- de usuarios totales dispersos sin nadie cerca de nadie.
--
-- search_path = '' (no "public"): mismo patrón endurecido que las otras
-- funciones security definer de 0002_rls.sql (private.has_accepted_social,
-- private.has_accepted_compat_request) — encontrado en auditoría posterior
-- que esta función se había quedado con search_path = public y referencias
-- sin cualificar, más débil frente a secuestro de search_path que el resto
-- del proyecto. Corregido para que todas las tablas usen el prefijo
-- explícito public., igual que el resto de funciones de seguridad.
create or replace function public.event_density(p_event_id uuid, p_window_minutes integer default 15)
returns numeric
language sql
security definer
set search_path = ''
as $$
    select case when attendees = 0 then 0
        else round(100.0 * active / attendees, 1)
    end
    from (
        select
            (select count(*) from public.event_attendees where event_id = p_event_id) as attendees,
            (select count(distinct profile_id) from public.analytics_events
                where event_id = p_event_id
                and created_at > now() - (p_window_minutes || ' minutes')::interval) as active
    ) counts;
$$;
