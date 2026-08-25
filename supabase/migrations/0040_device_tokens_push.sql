-- ---------------------------------------------------------------------------
-- Hallazgo real, el hueco de infraestructura mas grande documentado en
-- LOOP_STATE.md ("Pendiente real") y explicitamente citado en
-- growth_strategy.md: las notificaciones locales (NotificationsBadgeViewModel/
-- LocalNotifier) solo funcionan mientras el proceso de la app sigue vivo,
-- ninguna llega si el sistema mato el proceso, a diferencia de cualquier app
-- grande (Instagram/TikTok/Snapchat), que si notifican con el proceso muerto
-- via APNs/FCM. Esta migracion es la primera pieza real: el registro de
-- tokens de dispositivo. El disparador que llama a la Edge Function
-- (send-push) va en 0041_notify_push_trigger.sql, separado porque usa la
-- extension pg_net, que no esta disponible en PGlite (el harness de
-- pruebas local, supabase/local_verify) -- confirmado intentandolo aqui:
-- "extension pg_net is not available". Si existe en Supabase real, por eso
-- queda en su propia migracion en vez de forzarla junto a esta tabla (que
-- si se puede verificar de verdad en local).
--
-- Aviso de honestidad importante, mismo criterio que duel-ai/icebreaker-ai:
-- esto NO envia push de verdad todavia sin configurar credenciales reales
-- (ver el comentario de despliegue en supabase/functions/send-push/index.ts),
-- es la infraestructura real y completa, lista para activarse en cuanto
-- existan esas credenciales, no una simulacion.
-- ---------------------------------------------------------------------------

create table device_tokens (
    id uuid primary key default uuid_generate_v4(),
    profile_id uuid not null references profiles(id) on delete cascade,
    platform text not null check (platform in ('ios', 'android')),
    token text not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (profile_id, platform, token)
);

alter table device_tokens enable row level security;

-- Cada dispositivo solo gestiona su propio token -- el mismo patron de
-- "_own" ya usado en profiles/profile_sections, no el patron "solo
-- service_role" de ai_usage/duel_sessions, porque aqui SI necesita
-- escribir el cliente legitimo (al registrar el token), no solo el
-- servidor.
create policy device_tokens_select_own on device_tokens
    for select using ((select auth.uid()) = profile_id);

create policy device_tokens_insert_own on device_tokens
    for insert with check ((select auth.uid()) = profile_id);

create policy device_tokens_update_own on device_tokens
    for update using ((select auth.uid()) = profile_id)
    with check ((select auth.uid()) = profile_id);

create policy device_tokens_delete_own on device_tokens
    for delete using ((select auth.uid()) = profile_id);
