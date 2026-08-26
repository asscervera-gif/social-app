-- ============================================================================
-- SOCIAL — Fijar un chat arriba de la lista, comparado con
-- WhatsApp/Telegram/Messenger
--
-- Las tres dejan anclar una conversación (1:1 o de grupo) arriba de "Tus
-- chats" manteniendo pulsado -- confirmado que `chats` no tiene ninguna
-- columna de "fijado": solo `hidden_by_a/b` (0044_chats_hide.sql) y
-- `muted_by_a/b` (0047_message_notify_mute.sql). Extensión directa del
-- mismo patrón "dos columnas booleanas por participante + trigger que
-- impide tocar la del otro" ya usado dos veces en `chats` y una vez más
-- en `group_chat_members` (0064_group_chat_mute.sql) -- sin RLS nueva en
-- ningún caso: `chats_update`/`group_chat_members_update_own` ya cubren
-- cualquier columna propia, el trigger es lo único que falta.
--
-- A diferencia de `hidden_by_a/b` (que un mensaje nuevo real DESHACE,
-- 0044), fijar NO se deshace solo -- mismo criterio que WhatsApp/
-- Telegram: un chat fijado se queda fijado hasta que el propio usuario lo
-- desfije, sin importar cuánta actividad nueva llegue.
-- ============================================================================

alter table chats add column pinned_by_a boolean not null default false;
alter table chats add column pinned_by_b boolean not null default false;

-- Mismo patrón exacto que protect_chat_hidden_flags/protect_chat_muted_flags:
-- `(select auth.uid())` va ANTES de `current_user <> 'postgres'` en el AND
-- -- en el arnés local (PGlite) el primer intento real de evaluar
-- `auth.uid()` bajo un rol no-superusuario falla si nunca se había
-- evaluado antes en la sesión (ver 0044_chats_hide.sql para el detalle
-- completo de este hallazgo real).
create or replace function private.protect_chat_pinned_flags()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.pinned_by_a <> old.pinned_by_a and (select auth.uid()) <> old.user_a_id and current_user <> 'postgres' then
        new.pinned_by_a := old.pinned_by_a;
    end if;
    if new.pinned_by_b <> old.pinned_by_b and (select auth.uid()) <> old.user_b_id and current_user <> 'postgres' then
        new.pinned_by_b := old.pinned_by_b;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_chat_pinned_flags() from public, anon, authenticated;

drop trigger if exists trg_protect_chat_pinned_flags on chats;
create trigger trg_protect_chat_pinned_flags
    before update on chats
    for each row
    execute function private.protect_chat_pinned_flags();

-- group_chat_members ya es una fila POR MIEMBRO (0057_group_chats.sql) --
-- mismo criterio que `muted`/`hidden` en esa misma tabla: una sola
-- columna basta, la propia fila ya identifica de quién es. RLS
-- (`group_chat_members_update_own`, 0064) y el trigger de identidad
-- (`trg_protect_group_chat_member_identity`, ya protege `group_chat_id`/
-- `user_id`/`joined_at`) ya cubren esta columna sin cambios.
alter table group_chat_members add column if not exists pinned boolean not null default false;
