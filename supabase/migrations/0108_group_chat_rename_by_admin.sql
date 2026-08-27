-- ============================================================================
-- SOCIAL — Renombrar el grupo/cambiar su foto también para admins,
-- comparado con WhatsApp/Telegram/Messenger
--
-- Las tres apps de referencia dejan a CUALQUIER admin (no solo a quien
-- creó el grupo) renombrarlo o cambiarle la foto -- alcance real que
-- 0107_group_chat_admins.sql documentó explícitamente como pendiente al
-- ascender/descender admins y ampliar quién puede expulsar. Confirmado
-- en el propio código: `group_chats_update_own` (0057) sigue siendo
-- `using (created_by = auth.uid())`, sin ninguna vía real para un admin
-- ascendido (no creador).
--
-- Aplicando la lección real de la propia migración anterior (0107, dos
-- hallazgos de seguridad encontrados a medio construirla): esta vez la
-- guardia de columnas se escribe DESDE EL PRINCIPIO, no como corrección
-- posterior. `group_chats` (0057) nunca había necesitado una -- hasta
-- ahora, una sola política de UPDATE (solo el creador) hacía imposible
-- que nadie tocara `created_by`/`created_at` de rebote. Añadir una
-- SEGUNDA política permisiva (admins) sin guardia reabriría el mismo
-- riesgo real de "varias políticas permisivas se combinan con OR a
-- nivel de fila" ya encontrado en 0049/0064/0089/0093/0107: un admin
-- podría "robar" el grupo reescribiendo `created_by` a su propio id.
-- `private.is_group_admin` (0107) evita la misma recursión real de RLS
-- ya documentada en 0057/0107 (una política de `group_chats` no puede
-- consultar `group_chats` de nuevo con un `exists` normal sin ciclo).
-- ============================================================================

create policy group_chats_update_by_admin on group_chats
    for update
    using (private.is_group_admin(group_chats.id, (select auth.uid())))
    with check (private.is_group_admin(group_chats.id, (select auth.uid())));

create or replace function private.protect_group_chat_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if current_user <> 'postgres' then
        new.created_by := old.created_by;
        new.created_at := old.created_at;
    end if;
    return new;
end;
$$;

drop trigger if exists trg_protect_group_chat_identity on group_chats;
create trigger trg_protect_group_chat_identity
    before update on group_chats
    for each row
    execute function private.protect_group_chat_identity();
