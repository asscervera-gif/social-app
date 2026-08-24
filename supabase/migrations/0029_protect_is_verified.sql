-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo de seguridad real — `is_verified`
-- autoconcedible por el cliente
--
-- `profiles_update_own` (0002_rls.sql) solo comprueba que la fila sea la
-- propia (`auth.uid() = id`) — RLS en Postgres es por FILA, no por
-- COLUMNA, así que esa política nunca impidió a un cliente modificado
-- mandar directamente `UPDATE profiles SET is_verified = true WHERE id =
-- auth.uid()` vía la API REST de PostgREST, sin pasar por ningún flujo
-- de verificación real. Es el hallazgo de seguridad más grave de esta
-- sesión: la insignia de verificado (ya renderizada en varias pantallas)
-- podía autoconcederse. El resto de columnas de `profiles`
-- (display_name, avatar_*, interests, bio, is_invisible, location_public,
-- compat_public, last_lat/lng) SÍ son legítimamente controlables por el
-- propio usuario — solo `is_verified` necesita este refuerzo.
--
-- Solución: un trigger BEFORE UPDATE que revierte `is_verified` a su
-- valor anterior salvo que quien ejecuta la operación sea `service_role`
-- (el único rol que debe poder verificar cuentas de verdad, vía un panel
-- de moderación o proceso interno — fuera del alcance de este cliente).
-- Revertir en silencio (no lanzar excepción) para no romper actualizaciones
-- legítimas que incluyan `is_verified` sin cambiarlo de verdad.
-- ============================================================================

create or replace function private.protect_is_verified()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.is_verified <> old.is_verified and auth.role() <> 'service_role' then
        new.is_verified := old.is_verified;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_is_verified() from public, anon, authenticated;

drop trigger if exists trg_protect_is_verified on profiles;
create trigger trg_protect_is_verified
    before update on profiles
    for each row
    execute function private.protect_is_verified();
