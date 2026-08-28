-- ============================================================================
-- SOCIAL — Aviso real de nuevo inicio de sesión ("Nuevo dispositivo"),
-- comparado con Instagram/Facebook/Snapchat
--
-- Ronda anterior (0040_device_tokens_push.sql, cliente real en la ronda
-- 107 "Dispositivos conectados") ya registra un token real por
-- dispositivo/plataforma, pero nadie se entera nunca de que una sesión
-- real se abrió en un dispositivo NUEVO -- confirmado con grep de
-- "new_device|device_login|login_alert" sin resultados en todo el
-- repo. Instagram/Facebook/Snapchat mandan un aviso real ("Nuevo inicio
-- de sesión detectado") cada vez que la cuenta se usa desde un
-- dispositivo que no se había visto antes -- pieza real de seguridad de
-- cuenta, comparado con la 2FA completa (mucho más grande y arriesgada
-- de construir bien: tocaría el flujo de login real de Supabase Auth) --
-- alcance deliberadamente más pequeño y seguro esta ronda.
--
-- Diseño real: `device_tokens` ya tiene `unique(profile_id, platform,
-- token)`, y el cliente siempre hace `upsert(..., onConflict:
-- "profile_id,platform,token")` (PushTokenManager.kt/.swift) -- así que
-- un INSERT real en esa tabla (no un UPDATE del mismo conflicto) SOLO
-- ocurre la primera vez que ESE dispositivo/token concreto se registra,
-- el momento exacto real de "sesión nueva en un dispositivo nuevo". Un
-- trigger AFTER INSERT (nunca AFTER UPDATE) es la señal correcta sin
-- necesitar ninguna lógica adicional de "¿ya lo había visto antes?".
-- ============================================================================

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response', 'repost', 'story_share', 'screenshot', 'live_start', 'post_collab_invite', 'countdown_due', 'new_device_login'));

create or replace function private.notify_new_device_login()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (new.profile_id, new.profile_id, 'new_device_login', jsonb_build_object('actor_id', new.profile_id, 'platform', new.platform));
    return new;
end;
$$;

revoke execute on function private.notify_new_device_login() from public, anon, authenticated;

drop trigger if exists trg_notify_new_device_login on device_tokens;
create trigger trg_notify_new_device_login
    after insert on device_tokens
    for each row
    execute function private.notify_new_device_login();
