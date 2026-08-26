-- ============================================================================
-- SOCIAL — Silenciar un chat de grupo real, comparado con WhatsApp/
-- Instagram/Messenger: el chat 1:1 ya deja silenciar una conversación sin
-- salir de ella (`muted_by_a`/`muted_by_b`, 0047_message_notify_mute.sql),
-- pero un chat de grupo (con muchos más mensajes que un 1:1, mismo motivo
-- por el que WhatsApp lo hace casi imprescindible ahí) no tenía forma real
-- de silenciarse -- `notify_new_group_message()` (0058) notifica siempre a
-- TODOS los demás miembros, sin excepción.
--
-- Diseño distinto del 1:1 a propósito: `chats` es una fila COMPARTIDA por
-- dos personas, así que hacen falta dos columnas (`muted_by_a`/`_b`) más un
-- trigger que impida que cada quien toque la del otro. `group_chat_members`
-- ya es una fila POR MIEMBRO (una fila = una persona en un grupo), así que
-- una sola columna `muted` basta -- la propia fila ya identifica de quién
-- es. El mismo riesgo que si protegía el trigger del 1:1 (que alguien
-- silencie la copia ajena) aquí se cubre solo con RLS normal
-- (`using (user_id = auth.uid())`), sin necesidad de una columna extra ni
-- de un trigger que compare "de quién es la columna que cambió".
--
-- Sí hace falta un trigger para un riesgo DISTINTO, propio de esta tabla:
-- sin él, la política de UPDATE de más abajo (necesariamente amplia, para
-- poder tocar `muted`) dejaría a un miembro reescribir `group_chat_id` de
-- su propia fila -- "trasladando" su membresía a un grupo distinto sin
-- haber sido nunca invitado ahí, un agujero real de privilegios que
-- `with check (user_id = auth.uid())` por sí solo NO cierra (el nuevo
-- `user_id` seguiría siendo el suyo, solo cambiaría a qué grupo apunta).
-- Mismo patrón exacto que `protect_chat_muted_flags`/`protect_post_counts`:
-- RLS amplia + trigger que revierte las columnas que no deben tocarse.
-- ============================================================================

alter table group_chat_members add column if not exists muted boolean not null default false;

create policy group_chat_members_update_own on group_chat_members
    for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

create or replace function private.protect_group_chat_member_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if current_user <> 'postgres' then
        new.group_chat_id := old.group_chat_id;
        new.user_id := old.user_id;
        new.joined_at := old.joined_at;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_group_chat_member_identity() from public, anon, authenticated;

drop trigger if exists trg_protect_group_chat_member_identity on group_chat_members;
create trigger trg_protect_group_chat_member_identity
    before update on group_chat_members
    for each row
    execute function private.protect_group_chat_member_identity();

-- notify_new_group_message (0058): salta a quien tiene el grupo silenciado
-- -- mismo criterio de "silenciado no suprime nada más" que muted_by_a/b
-- del 1:1 (el mensaje se sigue guardando/mostrando con normalidad si abres
-- el chat, solo no genera aviso/push).
create or replace function private.notify_new_group_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  select
    gcm.user_id,
    new.sender_id,
    'group_message',
    jsonb_build_object('group_chat_id', new.group_chat_id, 'actor_id', new.sender_id)
  from public.group_chat_members gcm
  where gcm.group_chat_id = new.group_chat_id
    and gcm.user_id <> new.sender_id
    and not gcm.muted;
  return new;
end;
$$;

revoke execute on function private.notify_new_group_message() from public, anon, authenticated;
