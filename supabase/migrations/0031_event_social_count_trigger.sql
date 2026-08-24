-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo real — el ranking de Modo Evento
-- nunca se actualizaba
--
-- Auditando `event_attendees.social_count` (arreglado el hueco de
-- seguridad en la pasada anterior) se encontró un hueco funcional más
-- grave: NADA la incrementaba nunca, ni trigger ni código cliente en
-- ninguna plataforma — el ranking de "Modo Evento" (EventModeScreen.kt/
-- EventModeView.swift) mostraba siempre 0 socials para todo el mundo, sin
-- importar cuántos socials reales se intercambiaran durante el evento.
-- La función central del Modo Evento (competir por quién hace más socials
-- en el recinto) nunca funcionó de verdad.
--
-- Solución: un trigger AFTER UPDATE en `socials` que, cuando el estado
-- pasa a 'accepted', incrementa `social_count` en `event_attendees` para
-- ambas partes, pero SOLO si ambas son asistentes del MISMO evento
-- actualmente activo (`now() between starts_at and ends_at`) — un social
-- fuera de un evento no debe contar para ningún ranking.
-- ============================================================================

create or replace function private.increment_event_social_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.status = 'accepted' and (old.status is distinct from 'accepted') then
        update public.event_attendees
        set social_count = social_count + 1
        where profile_id in (new.requester_id, new.addressee_id)
          and event_id in (
              select ea1.event_id
              from public.event_attendees ea1
              join public.event_attendees ea2
                on ea1.event_id = ea2.event_id
              join public.events e on e.id = ea1.event_id
              where ea1.profile_id = new.requester_id
                and ea2.profile_id = new.addressee_id
                and now() between e.starts_at and e.ends_at
          );
    end if;
    return new;
end;
$$;

revoke execute on function private.increment_event_social_count() from public, anon, authenticated;

drop trigger if exists trg_increment_event_social_count on socials;
create trigger trg_increment_event_social_count
    after update on socials
    for each row
    execute function private.increment_event_social_count();
