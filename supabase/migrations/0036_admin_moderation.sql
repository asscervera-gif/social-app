-- ============================================================================
-- SOCIAL — Fase 10: panel de moderación real (primera pieza)
--
-- Hallazgo real documentado desde hace muchas pasadas en LOOP_STATE.md
-- ("Pendiente real"): `reports` existe, tiene RLS, el cliente ya inserta
-- denuncias reales (`SafetyManager.kt/.swift.report()`) — pero nadie
-- podía leerlas nunca. `reports_insert_own` es la única política de esa
-- tabla; sin política de SELECT, ni siquiera el propio denunciante puede
-- volver a ver su denuncia, y desde luego ningún humano del lado de
-- SOCIAL podía revisarlas sin entrar directamente a la base de datos con
-- una clave privilegiada. Esto construye la primera pieza real de
-- moderación: una columna `is_admin` (misma familia y mismo patrón que
-- `is_verified`, 0029 — protegida por trigger, nunca autoconcedible por
-- el cliente) y políticas que dejan a un admin real leer y resolver
-- denuncias.
--
-- Esto NO es un panel de moderación completo (eso seguiría necesitando
-- una interfaz dedicada, fuera de alcance de una sola migración) — es la
-- base de datos real que ese panel necesitaría, más una pantalla mínima
-- en el propio cliente para el caso de uso más simple: un admin
-- revisando la cola de denuncias abiertas.
-- ============================================================================

alter table profiles add column is_admin boolean not null default false;

create or replace function private.protect_is_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.is_admin <> old.is_admin and auth.role() <> 'service_role' then
        new.is_admin := old.is_admin;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_is_admin() from public, anon, authenticated;

drop trigger if exists trg_protect_is_admin on profiles;
create trigger trg_protect_is_admin
    before update on profiles
    for each row
    execute function private.protect_is_admin();

-- Un admin real (concedido a mano por `service_role`, nunca por el
-- propio cliente) puede leer todas las denuncias y marcarlas como
-- revisadas/descartadas. El denunciante sigue sin poder leer las suyas
-- propias después de insertarlas — eso no cambia aquí, sigue siendo una
-- decisión de producto ya tomada, no un descuido.
create policy reports_select_admin on reports
    for select
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );

create policy reports_update_admin on reports
    for update
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    )
    with check (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
    );
