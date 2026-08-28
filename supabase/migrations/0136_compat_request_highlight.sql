-- ============================================================================
-- SOCIAL — "Interés destacado" al pedir ver compatibilidad, comparado con
-- Tinder/Bumble (Super Like)
--
-- Hallazgo real, confirmado con `grep`: no existe ningún concepto de
-- "favorito"/"interés destacado" en Match -- `compat_requests`
-- (0001_schema.sql) solo tiene una fila neutra por solicitud, sin
-- distinguir intensidad de interés. MatchViewModel.kt/.swift solo llaman
-- a `requestCompatibility()`, siempre igual. Tinder/Bumble sí dejan
-- destacar tu interés frente al toque normal (Super Like) -- SOCIAL no
-- tenía equivalente.
--
-- Diseño real: columna `highlighted`, límite real de UNA solicitud
-- destacada por día por persona -- reforzado con un índice único parcial
-- (no un trigger que la rebaje en silencio), mismo criterio de "la base
-- de datos es la fuente de verdad" ya aplicado en constraints reales de
-- esta sesión. Un segundo intento el mismo día real recibe un error real
-- (violación de unique), no un downgrade silencioso -- el cliente puede
-- mostrar un mensaje claro ("Ya has destacado una solicitud hoy") en vez
-- de fingir que se destacó cuando no fue así.
-- ============================================================================

alter table compat_requests add column highlighted boolean not null default false;

-- `created_at::date` a secas depende del timezone de la propia sesión
-- (STABLE, no IMMUTABLE) -- Postgres rechaza esa expresión en un índice.
-- Fijar explícitamente a UTC la hace real e IMMUTABLE (no depende de
-- ninguna configuración de sesión), hallazgo real encontrado aplicando
-- esta misma migración contra el motor real.
create unique index idx_compat_requests_highlighted_daily
    on compat_requests (requester_id, ((created_at at time zone 'utc')::date))
    where highlighted;

create or replace function private.notify_new_compat_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  values (
    new.target_id,
    new.requester_id,
    'compat_request',
    jsonb_build_object('compat_request_id', new.id, 'actor_id', new.requester_id, 'highlighted', new.highlighted)
  );
  return new;
end;
$$;
