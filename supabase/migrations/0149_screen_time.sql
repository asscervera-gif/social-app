-- ============================================================================
-- SOCIAL — Tiempo en pantalla real ("Bienestar digital"), comparado con
-- Instagram ("Tu actividad")/TikTok (Screen Time Management)/Facebook
-- ("Tu tiempo en Facebook")/Snapchat
--
-- Confirmado que no existe ningún rastro de `screen_time|time_limit|
-- daily_limit|usage_time` ni tabla de sesiones de uso en todo el repo.
-- `AnalyticsManager.track()` ya existe pero solo registra eventos
-- puntuales (post_created, signup_completed...), nunca CUÁNTO tiempo
-- real pasa alguien dentro de la app -- hueco real de confianza/
-- seguridad presente en las 4 apps de referencia.
--
-- Diseño real: `app_sessions` (una fila real por cada vez que la app
-- pasa a primer plano hasta que vuelve a segundo plano) + dos columnas
-- nuevas en `profiles` para el límite diario opcional. Alcance
-- deliberadamente acotado: SIN pg_cron ni bloqueo real del uso al
-- llegar al límite (eso necesitaría APIs nativas de Screen Time/Family
-- Controls, fuera de alcance) -- solo un recordatorio local real cuando
-- el propio cliente detecta que ya pasó el límite, mismo criterio de
-- "límite blando" ya usado en apps de bienestar digital reales.
-- ============================================================================

create table app_sessions (
    id uuid primary key default uuid_generate_v4(),
    user_id uuid not null references profiles(id) on delete cascade,
    started_at timestamptz not null default now(),
    ended_at timestamptz,
    -- Calculada por el cliente al cerrar la sesión real (ended_at -
    -- started_at), no por un trigger -- mismo criterio que
    -- reel_view_count/post_views: la duración exacta de una sesión de
    -- uso no es algo que valga la pena recalcular en el servidor.
    duration_seconds integer
);

alter table app_sessions enable row level security;

create index idx_app_sessions_user_id on app_sessions(user_id, started_at desc);

-- Cada quien gestiona solo sus propias sesiones -- mismo criterio que
-- recent_searches/hashtag_follows, nadie más necesita ver cuánto tiempo
-- pasa otra persona en la app.
create policy app_sessions_own on app_sessions
    for all
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

alter table profiles add column daily_time_limit_minutes integer check (daily_time_limit_minutes is null or daily_time_limit_minutes > 0);
alter table profiles add column daily_reminder_enabled boolean not null default false;
