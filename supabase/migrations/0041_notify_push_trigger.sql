-- ---------------------------------------------------------------------------
-- Disparador real: en cuanto se inserta un aviso (0006_notification_triggers.sql
-- ya crea la fila en `notifications` para social/follow/fight/like/
-- compat_request), se llama a la Edge Function `send-push`
-- (supabase/functions/send-push/index.ts) via pg_net -- mismo patron
-- documentado oficialmente por Supabase para invocar una Edge Function
-- desde un trigger de base de datos.
--
-- Aviso de honestidad, importante: NO verificable en el harness de pruebas
-- local (supabase/local_verify) -- PGlite (Postgres compilado a WASM) no
-- trae la extension pg_net, confirmado intentando aplicar esta migracion
-- ahi ("extension pg_net is not available"). Si es una extension real y
-- estandar en Supabase (no autoalojado a medida), por eso sigue siendo
-- codigo real para produccion, solo que esta migracion en concreto no
-- pasa por el mismo harness de verificacion que las demas 40.
--
-- `net.http_post` requiere que el proyecto real tenga configurados
-- `app.settings.supabase_url` y `app.settings.service_role_key` a nivel de
-- base de datos -- son secretos reales del proyecto, nunca deben
-- commitearse, asi que no se pueden fijar desde una migracion. Paso de
-- despliegue real, documentado, no una simulacion:
--   alter database postgres set app.settings.supabase_url = 'https://TU-PROYECTO.supabase.co';
--   alter database postgres set app.settings.service_role_key = 'TU_SERVICE_ROLE_KEY';
-- Sin ese paso, el trigger no rompe nada -- simplemente no llega a llamar
-- a net.http_post (current_setting con el segundo argumento `true` no
-- lanza error si la clave no existe, devuelve null), y la insercion del
-- aviso en `notifications` sigue funcionando con total normalidad.
-- ---------------------------------------------------------------------------

create extension if not exists pg_net with schema extensions;

create or replace function notify_push_on_new_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    edge_url text;
    service_key text;
begin
    edge_url := current_setting('app.settings.supabase_url', true);
    service_key := current_setting('app.settings.service_role_key', true);
    if edge_url is null or service_key is null then
        return new;
    end if;

    perform net.http_post(
        url := edge_url || '/functions/v1/send-push',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || service_key,
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object('notification_id', new.id)
    );
    return new;
end;
$$;

create trigger notifications_push_trigger
    after insert on notifications
    for each row execute function notify_push_on_new_notification();
