-- ============================================================================
-- SOCIAL — ocultar una conversación de "Tus chats"
--
-- Hallazgo real, comparado con WhatsApp/Instagram/Messenger: `chats` no
-- tenía NINGUNA política de delete (confirmado -- ver 0002_rls.sql, solo
-- select/insert/update) ni ninguna forma de quitar una conversación de la
-- lista. Un borrado real de la fila `chats` no encaja aquí: es compartida
-- entre dos personas, y borrarla de verdad se llevaría también los
-- mensajes de la OTRA persona sin su consentimiento -- no es lo que hace
-- ninguna app grande ("eliminar" en WhatsApp/Instagram solo la quita de
-- TU lista, la otra persona sigue viéndola igual).
--
-- Dos columnas booleanas, una por participante, protegidas por trigger:
-- cada quien solo puede ocultar SU PROPIA copia, nunca la de la otra
-- persona. Un mensaje nuevo real restaura ambos flags -- un chat oculto
-- para siempre en cuanto llega actividad real sería peor que no tener la
-- función (mensajes perdidos de la vista sin ningún aviso), mismo
-- criterio que "un chat archivado reaparece si te escriben de nuevo" en
-- cualquier app grande.
--
-- Aviso de honestidad importante, aprendido del hallazgo crítico de
-- 0039/0042 (protect_ban_columns): el trigger de protección usa
-- `current_user <> 'postgres'`, NO `security definer` en sí mismo -- el
-- mismo patrón ya corregido ahí. `unhide_chat_on_new_message` SÍ es
-- `security definer` a propósito: necesita poder tocar el flag del OTRO
-- participante (quien no disparó el mensaje), y solo una función
-- security definer eleva `current_user` a su propio dueño (postgres)
-- para que el trigger de protección la reconozca como confiable —
-- exactamente el mismo mecanismo que ya usa `admin_ban_user` para
-- saltarse `protect_ban_columns` de forma legítima.
--
-- Nota de robustez de pruebas (no de producción): `(select auth.uid())`
-- va ANTES de `current_user <> 'postgres'` en el AND -- en Supabase real
-- da igual el orden (authenticated/anon ya tienen USAGE en el esquema
-- auth por defecto), pero en el arnés local (PGlite, sin ese grant) el
-- primer intento real de evaluar `auth.uid()` bajo un rol no-superusuario
-- falla con "permission denied for schema auth" si nunca se había
-- evaluado antes en la sesión -- confirmado con pruebas aisladas. Con
-- `auth.uid()` primero, la propia llamada de `service_role` (que sí
-- tiene bypass total) ya lo "calienta" de verdad en vez de saltárselo
-- por el corte del AND, y las pruebas de `test_rls.mjs` quedan
-- deterministas sin depender del orden de ejecución.
-- ============================================================================

alter table chats add column hidden_by_a boolean not null default false;
alter table chats add column hidden_by_b boolean not null default false;

create or replace function private.protect_chat_hidden_flags()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.hidden_by_a <> old.hidden_by_a and (select auth.uid()) <> old.user_a_id and current_user <> 'postgres' then
        new.hidden_by_a := old.hidden_by_a;
    end if;
    if new.hidden_by_b <> old.hidden_by_b and (select auth.uid()) <> old.user_b_id and current_user <> 'postgres' then
        new.hidden_by_b := old.hidden_by_b;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_chat_hidden_flags() from public, anon, authenticated;

drop trigger if exists trg_protect_chat_hidden_flags on chats;
create trigger trg_protect_chat_hidden_flags
    before update on chats
    for each row
    execute function private.protect_chat_hidden_flags();

create or replace function private.unhide_chat_on_new_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.chats
    set hidden_by_a = false, hidden_by_b = false
    where id = new.chat_id and (hidden_by_a or hidden_by_b);
    return new;
end;
$$;

revoke execute on function private.unhide_chat_on_new_message() from public, anon, authenticated;

drop trigger if exists trg_unhide_chat_on_new_message on messages;
create trigger trg_unhide_chat_on_new_message
    after insert on messages
    for each row
    execute function private.unhide_chat_on_new_message();
