-- ============================================================================
-- SOCIAL — Fondo de chat (wallpaper) por persona, comparado con
-- WhatsApp/Telegram/Messenger
--
-- Las tres dejan personalizar el fondo de una conversación, y cada quien
-- ve el suyo propio (no es una decisión compartida) -- confirmado que
-- `chats`/`group_chat_members` no tienen ninguna columna de "fondo":
-- grep de wallpaper/chat_theme sobre supabase/migrations/*.sql no
-- devuelve nada. Extensión directa del mismo patrón ya usado tres veces
-- en `chats` (hidden_by_a/b 0044, muted_by_a/b 0047, pinned_by_a/b 0081)
-- y una vez en `group_chat_members` (muted 0064, pinned 0081): dos
-- columnas + trigger que protege la ajena en `chats` (fila compartida
-- por dos personas), una sola columna en `group_chat_members` (fila ya
-- por miembro, se identifica sola).
--
-- Solo fondos predefinidos (una `key` de texto corta, ej. "sunset",
-- "ocean"), sin subida de fotos propias -- a diferencia de WhatsApp, para
-- acotar el alcance real de esta ronda. El cliente decide la paleta de
-- claves válidas; aquí no hace falta CHECK porque un valor desconocido
-- simplemente no coincidiría con ningún fondo dibujado por el cliente
-- (no rompe nada, mismo criterio que avatar_config en profiles).
-- ============================================================================

alter table chats add column wallpaper_by_a text;
alter table chats add column wallpaper_by_b text;

-- Mismo patrón exacto que protect_chat_pinned_flags/protect_chat_muted_flags.
create or replace function private.protect_chat_wallpaper_flags()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.wallpaper_by_a is distinct from old.wallpaper_by_a and (select auth.uid()) <> old.user_a_id and current_user <> 'postgres' then
        new.wallpaper_by_a := old.wallpaper_by_a;
    end if;
    if new.wallpaper_by_b is distinct from old.wallpaper_by_b and (select auth.uid()) <> old.user_b_id and current_user <> 'postgres' then
        new.wallpaper_by_b := old.wallpaper_by_b;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_chat_wallpaper_flags() from public, anon, authenticated;

drop trigger if exists trg_protect_chat_wallpaper_flags on chats;
create trigger trg_protect_chat_wallpaper_flags
    before update on chats
    for each row
    execute function private.protect_chat_wallpaper_flags();

-- group_chat_members ya es una fila POR MIEMBRO -- una sola columna
-- basta, la propia fila ya identifica de quién es (mismo criterio que
-- muted/pinned en esa misma tabla, 0064/0081). RLS
-- (group_chat_members_update_own) y el trigger de identidad ya existente
-- (trg_protect_group_chat_member_identity) ya cubren esta columna sin
-- cambios.
alter table group_chat_members add column if not exists wallpaper_key text;
