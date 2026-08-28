-- ============================================================================
-- SOCIAL — Sonido de notificación personalizado por chat, comparado con
-- WhatsApp/Telegram/Messenger/Instagram DM
--
-- `muted_push_kinds` (0052_notification_prefs.sql) solo apaga categorías
-- enteras, y `muted_by_a/b` (0047) solo silencia un chat completo (todo
-- o nada) -- ninguna de las dos deja asignar un TONO distinto por
-- conversación. Confirmado con grep de "ringtone|notification_sound"
-- sin resultados en todo el repo.
--
-- Diseño real: personal, nunca compartido -- mismo criterio exacto ya
-- usado por `wallpaper_by_a/b` (0139_chat_wallpaper.sql): cada
-- participante real de un chat 1:1 elige SU PROPIO tono, nunca el de la
-- otra persona (`notification_sound_by_a/b` + mismo trigger de
-- protección). `group_chat_members` ya es una fila POR MIEMBRO, una
-- sola columna basta -- mismo criterio que `muted`/`pinned`/
-- `wallpaper_key` en esa misma tabla.
--
-- Aviso de honestidad, mismo criterio que send-push/duel-ai/icebreaker-ai:
-- la columna, la RLS y el paso real del nombre elegido hasta la Edge
-- Function (send-push) son reales y completos -- pero los tonos
-- distintos de "default" (ej. "chime"/"bell"/"ping") solo suenan
-- distinto de verdad una vez existan los archivos de audio reales
-- empaquetados en cada app (`res/raw/*.mp3` en Android, `*.caf` en
-- iOS), que no se generan aquí (no hay forma real de crear un asset de
-- audio real desde este entorno). Sin esos archivos, cualquier nombre
-- que no sea "default" cae de vuelta al tono del sistema en tiempo de
-- ejecución -- documentado así en vez de fingir un sonido real que
-- todavía no existe como archivo.
-- ============================================================================

alter table chats add column notification_sound_by_a text;
alter table chats add column notification_sound_by_b text;

-- Mismo patrón exacto que protect_chat_wallpaper_flags (0139).
create or replace function private.protect_chat_notification_sound_flags()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.notification_sound_by_a is distinct from old.notification_sound_by_a and (select auth.uid()) <> old.user_a_id and current_user <> 'postgres' then
        new.notification_sound_by_a := old.notification_sound_by_a;
    end if;
    if new.notification_sound_by_b is distinct from old.notification_sound_by_b and (select auth.uid()) <> old.user_b_id and current_user <> 'postgres' then
        new.notification_sound_by_b := old.notification_sound_by_b;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_chat_notification_sound_flags() from public, anon, authenticated;

drop trigger if exists trg_protect_chat_notification_sound_flags on chats;
create trigger trg_protect_chat_notification_sound_flags
    before update on chats
    for each row
    execute function private.protect_chat_notification_sound_flags();

-- group_chat_members ya es una fila POR MIEMBRO -- una sola columna
-- basta, la propia fila ya identifica de quién es (mismo criterio que
-- muted/pinned/wallpaper_key en esa misma tabla). RLS
-- (group_chat_members_update_own) y el trigger de identidad ya
-- existente (trg_protect_group_chat_member_identity) ya cubren esta
-- columna sin cambios.
alter table group_chat_members add column if not exists notification_sound text;
