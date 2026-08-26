-- ============================================================================
-- SOCIAL — ocultar un chat de grupo de "Grupos" real, comparado con
-- WhatsApp/Instagram/Messenger: el chat 1:1 ya deja ocultar una
-- conversación de la lista sin salir de ella ni borrarla
-- (hidden_by_a/hidden_by_b, 0044_chats_hide.sql), pero un chat de grupo
-- no tenía forma de quitarse de la lista "Grupos" salvo salir del todo
-- (perdiendo la membresía real) -- en WhatsApp/Messenger, "archivar" un
-- grupo (igual que un 1:1) lo saca de la lista principal SIN salir de él.
--
-- Diseño más simple que el 1:1 a propósito, mismo motivo ya documentado en
-- 0064 (silenciar) y 0057: `group_chat_members` ya es una fila POR
-- MIEMBRO, así que una sola columna `hidden` basta -- la propia fila
-- identifica de quién es. Sin trigger de protección nuevo:
-- `group_chat_members_update_own` (0064) ya deja a cada quien tocar
-- cualquier columna de SU PROPIA fila, y `trg_protect_group_chat_member_identity`
-- (0064) ya protege `group_chat_id`/`user_id`/`joined_at` sin importar qué
-- otra columna se esté cambiando a la vez -- `hidden` queda cubierto
-- gratis por esas dos piezas ya existentes, igual que `muted` lo estuvo.
--
-- Un mensaje nuevo real restaura el flag para todo el grupo -- mismo
-- criterio exacto que `unhide_chat_on_new_message` (0044): un grupo
-- oculto para siempre en cuanto llega actividad real sería peor que no
-- tener la función.
-- ============================================================================

alter table group_chat_members add column if not exists hidden boolean not null default false;

create or replace function private.unhide_group_on_new_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.group_chat_members
    set hidden = false
    where group_chat_id = new.group_chat_id and hidden = true;
    return new;
end;
$$;

revoke execute on function private.unhide_group_on_new_message() from public, anon, authenticated;

drop trigger if exists trg_unhide_group_on_new_message on group_messages;
create trigger trg_unhide_group_on_new_message
    after insert on group_messages
    for each row
    execute function private.unhide_group_on_new_message();
