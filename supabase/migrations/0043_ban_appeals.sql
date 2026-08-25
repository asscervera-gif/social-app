-- ============================================================================
-- SOCIAL — apelación real de baneo
--
-- Hallazgo real, comparado con Instagram/TikTok/Facebook, y directamente
-- ligado a growth_strategy.md sección 5 ("seguridad percibida... la
-- confianza es el requisito de adopción más alto, no una función
-- secundaria"): BannedScreen/BannedView (AppRoot.kt/AppRootView.swift) ya
-- muestra el motivo real del baneo y deja cerrar sesión, pero no ofrece
-- NINGUNA forma de apelar la decisión -- cualquier app grande deja
-- solicitar una revisión humana. Sin esto, un baneo equivocado (denuncia
-- falsa, error de moderación) es definitivo sin recurso.
--
-- Mismo patrón exacto ya verificado en 0036_admin_moderation.sql para
-- `reports`: el propio usuario puede insertar y leer SU apelación (no las
-- ajenas), un admin real (is_admin, columna protegida por trigger, nunca
-- autoconcedible) puede leer y resolver todas. Un usuario baneado sigue
-- teniendo una sesión de Supabase Auth válida (el baneo se aplica del lado
-- del cliente mostrando BannedScreen, y del lado del servidor revirtiendo
-- columnas de perfil -- 0042 -- no revocando el JWT), así que puede
-- insertar su apelación con normalidad.
-- ============================================================================

create table ban_appeals (
    id uuid primary key default uuid_generate_v4(),
    profile_id uuid not null references profiles(id) on delete cascade,
    message text not null,
    status text not null default 'open' check (status in ('open', 'reviewed', 'dismissed')),
    created_at timestamptz not null default now()
);

create index if not exists idx_ban_appeals_profile on ban_appeals(profile_id);

alter table ban_appeals enable row level security;

create policy ban_appeals_insert_own on ban_appeals
    for insert
    with check (profile_id = (select auth.uid()));

create policy ban_appeals_select_own on ban_appeals
    for select
    using (profile_id = (select auth.uid()));

create policy ban_appeals_select_admin on ban_appeals
    for select
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );

create policy ban_appeals_update_admin on ban_appeals
    for update
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    )
    with check (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );
