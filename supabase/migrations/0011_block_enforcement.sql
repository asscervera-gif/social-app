-- ============================================================================
-- SOCIAL — Fase 8: bloqueo aplicado de verdad en RLS, no solo ocultado en UI
--
-- Hallazgo real: `socials_insert`, `follows_write_own` y
-- `compat_requests_insert` (0002_rls.sql) solo comprobaban
-- `requester_id/follower_id = auth.uid()` — ninguna comprobaba `blocks`.
-- El fix de esta sesión en MatchViewModel/HomeViewModel oculta a bloqueados
-- de las listas de descubrimiento, pero un cliente modificado podía seguir
-- mandando un `social`/`follow`/`compat_request` directamente a (o desde)
-- alguien bloqueado, saltándose la UI por completo — y RLS es el límite de
-- confianza real de este proyecto (ver security_checklist.md), no la UI.
-- ============================================================================

-- Bloqueo en cualquier dirección entre a y b — mismo patrón que
-- private.has_accepted_social (security definer + search_path vacío +
-- revoke de ejecución directa).
create or replace function private.is_blocked(a uuid, b uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

revoke execute on function private.is_blocked(uuid, uuid) from public, anon, authenticated;
grant execute on function private.is_blocked(uuid, uuid) to authenticated, service_role;

drop policy if exists socials_insert on socials;
create policy socials_insert on socials
    for insert
    with check (
        requester_id = (select auth.uid())
        and not private.is_blocked(requester_id, addressee_id)
    );

drop policy if exists follows_write_own on follows;
create policy follows_write_own on follows
    for all
    using (follower_id = (select auth.uid()))
    with check (
        follower_id = (select auth.uid())
        and not private.is_blocked(follower_id, followee_id)
    );

drop policy if exists compat_requests_insert on compat_requests;
create policy compat_requests_insert on compat_requests
    for insert
    with check (
        requester_id = (select auth.uid())
        and not private.is_blocked(requester_id, target_id)
    );
