-- ============================================================================
-- SOCIAL — Marcar un chat como no leído manualmente, comparado con
-- WhatsApp/Telegram/Messenger
--
-- Las tres dejan volver a marcar como "no leído" una conversación ya
-- leída del todo -- útil para acordarse de responder más tarde, sin tener
-- que dejar el mensaje real sin leer de verdad (el remitente NO debe
-- perder su "✓✓ leído" solo porque el destinatario quiera un recordatorio
-- visual). Confirmado en el propio código: `hasUnread`
-- (ChatListViewModel.kt/.swift) se calcula ÚNICAMENTE a partir de
-- `messages.read_at` del último mensaje real -- no existe ningún override
-- manual, así que la única forma real de "reaparecer" en negrita sería
-- desmarcar `read_at` del mensaje real, lo que SÍ rompería el recibo de
-- lectura real que ve la otra persona.
--
-- Diseño real: exactamente el mismo patrón "dos columnas booleanas por
-- participante + trigger que impide tocar la del otro" ya usado tres
-- veces en `chats` (hidden_by_a/b, muted_by_a/b, pinned_by_a/b) -- una
-- capa de override puramente visual y personal, por encima del estado
-- real de lectura, que nunca toca `messages.read_at`. Se limpia sola la
-- próxima vez que la propia persona abre el chat de verdad (mismo
-- momento en que el cliente ya marca `read_at` real) -- no necesita
-- trigger propio para eso, el cliente ya hace esa escritura en la misma
-- llamada.
--
-- Hallazgo real de paso, al intentar aplicar lo mismo a `group_chat_members`:
-- a diferencia del chat 1:1 (`hasUnread` ya se calcula de verdad a partir
-- de `messages.read_at` del último mensaje), la lista de chats de grupo
-- NO TIENE ningún concepto de "no leído" en absoluto -- ni contador de
-- lectura, ni comparación de fecha -- así que un simple flag manual ahí
-- no tendría ningún estado real que combinar y sería un botón sin efecto
-- visible. Se añade aquí mismo `group_chat_members.last_read_at`
-- (nullable, null = nunca abierto) para que el flag manual de grupo
-- tenga sentido real desde el principio, no como base de una función
-- futura -- mismo criterio que `messages.read_at` para el 1:1, aplicado
-- ahora también a "¿hay un mensaje de grupo real más nuevo que la última
-- vez que abrí este grupo?".
-- ============================================================================

alter table chats add column marked_unread_by_a boolean not null default false;
alter table chats add column marked_unread_by_b boolean not null default false;
alter table group_chat_members add column marked_unread boolean not null default false;
alter table group_chat_members add column last_read_at timestamptz;

create or replace function private.protect_chat_unread_flags()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.marked_unread_by_a <> old.marked_unread_by_a and (select auth.uid()) <> old.user_a_id and current_user <> 'postgres' then
        new.marked_unread_by_a := old.marked_unread_by_a;
    end if;
    if new.marked_unread_by_b <> old.marked_unread_by_b and (select auth.uid()) <> old.user_b_id and current_user <> 'postgres' then
        new.marked_unread_by_b := old.marked_unread_by_b;
    end if;
    return new;
end;
$$;

drop trigger if exists trg_protect_chat_unread_flags on chats;
create trigger trg_protect_chat_unread_flags
    before update on chats
    for each row execute function private.protect_chat_unread_flags();
