-- ============================================================================
-- SOCIAL — Silenciar una cuenta real (sin dejar de seguir ni bloquear),
-- comparado con Instagram/Twitter/X/Facebook
--
-- Las cuatro dejan silenciar a una persona concreta -- sus publicaciones
-- dejan de aparecer en tu feed/Reels, SIN dejar de seguirla, SIN
-- bloquearla y SIN que ella se entere nunca (mismo criterio real de
-- "gestionar sin confrontación" ya usado en `restricts`,
-- 0093_restrict_account.sql). Confirmado en el propio código: `grep` de
-- "muted_account"/"silenciar cuenta" en todo el repo no encontró NADA --
-- SOCIAL ya tenía `blocks` (corte completo), `restricts` (oculta
-- comentarios/presencia a esa persona) y `muted_feed_keywords` (0116,
-- silencia por PALABRA, no por autor), pero ninguna de las tres cubre
-- "no quiero ver más publicaciones de ESTA persona en concreto".
--
-- Diseño deliberadamente ligero, MÁS SIMPLE que `restricts`: a diferencia
-- de `restricts` (necesita ser visible también para la propia persona
-- restringida en `comments_select`, mismo motivo del primer caso real de
-- esta sesión de alguien DISTINTO del dueño de la fila tocándola vía RLS
-- directa), silenciar es una preferencia PURAMENTE del cliente que la
-- activa -- filtrado en HomeViewModel/ReelsViewModel (mismo mecanismo
-- exacto ya usado para `muted_feed_keywords`), nunca en RLS de
-- `posts`/`reels`. Por eso `muted_accounts_select_own` basta (nadie más
-- necesita leer esta tabla), sin trigger ni función security definer.
-- ============================================================================

create table muted_accounts (
    muter_id uuid not null references profiles(id) on delete cascade,
    muted_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (muter_id, muted_id),
    check (muter_id <> muted_id)
);

alter table muted_accounts enable row level security;

create policy muted_accounts_select_own on muted_accounts
    for select
    using (muter_id = (select auth.uid()));

create policy muted_accounts_insert_own on muted_accounts
    for insert
    with check (muter_id = (select auth.uid()));

create policy muted_accounts_delete_own on muted_accounts
    for delete
    using (muter_id = (select auth.uid()));
