-- ============================================================================
-- SOCIAL — Verificación real (insignia azul), comparado con
-- Instagram/Twitter/TikTok
--
-- Las tres dejan al usuario SOLICITAR la verificación; un equipo revisa y
-- aprueba o rechaza. Hallazgo real: `profiles.is_verified`
-- (0001_schema.sql) existe desde el principio y ya está protegido de
-- verdad contra auto-concesión (`trg_protect_is_verified`,
-- 0029_protect_is_verified.sql) -- la insignia incluso se PINTA de verdad
-- en varias pantallas (PerfilScreen.kt/ProfileViewerScreen.kt/
-- SearchScreen.kt y sus equivalentes iOS). Pero no existía NINGÚN camino
-- para que `is_verified` llegara a ser `true` salvo escribirlo a mano en
-- la base de datos -- ni panel de admin, ni solicitud de usuario. Mismo
-- patrón exacto ya construido para baneos/apelaciones
-- (0037_admin_ban.sql/0043_ban_appeals.sql): tabla de solicitudes +
-- función `admin_set_*()` que comprueba `is_admin` del llamante antes de
-- tocar la columna protegida, en vez de una política RLS de UPDATE
-- abierta sobre `profiles` para admins (superficie de ataque mucho mayor).
-- ============================================================================

create table verification_requests (
    id uuid primary key default uuid_generate_v4(),
    profile_id uuid not null references profiles(id) on delete cascade,
    message text not null,
    status text not null default 'open' check (status in ('open', 'approved', 'rejected')),
    created_at timestamptz not null default now(),
    check (char_length(message) between 1 and 500)
);

create index if not exists idx_verification_requests_profile on verification_requests(profile_id);

alter table verification_requests enable row level security;

create policy verification_requests_insert_own on verification_requests
    for insert
    with check (profile_id = (select auth.uid()));

create policy verification_requests_select_own on verification_requests
    for select
    using (profile_id = (select auth.uid()));

create policy verification_requests_select_admin on verification_requests
    for select
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );

create policy verification_requests_update_admin on verification_requests
    for update
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );

-- Mismo patrón exacto que admin_ban_user() (0037_admin_ban.sql): la
-- autorización real vive DENTRO de la función (is_admin del CALLER
-- comprobado explícitamente), no en una política RLS de UPDATE sobre
-- `profiles` -- un bug en esa política habría dejado a un admin
-- comprometido tocar cualquier columna de cualquier perfil, no solo la
-- verificación.
create or replace function admin_set_verified(p_target_id uuid, p_verified boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller_is_admin boolean;
begin
    select is_admin into caller_is_admin from public.profiles where id = (select auth.uid());
    if caller_is_admin is not true then
        raise exception 'admin_set_verified: caller is not an admin';
    end if;

    -- Misma elevación local a esta transacción que admin_ban_user() --
    -- trg_protect_is_verified (0029) solo deja pasar el cambio cuando
    -- auth.role() = 'service_role', y ese rol no cambia solo por ser esta
    -- una función security definer.
    perform set_config('app.role', 'service_role', true);

    update public.profiles set is_verified = p_verified where id = p_target_id;
end;
$$;

revoke execute on function admin_set_verified(uuid, boolean) from public, anon;
grant execute on function admin_set_verified(uuid, boolean) to authenticated;
