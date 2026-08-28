-- ============================================================================
-- SOCIAL — "Vaciar conversación" real, comparado con WhatsApp/Telegram/
-- Instagram DM/Facebook Messenger
--
-- "Eliminar para mí" (0118_delete_message_for_me.sql) ya deja borrar un
-- mensaje SUELTO solo de la propia vista, pero no hay ninguna acción
-- real para vaciar el historial COMPLETO de un chat de una vez --
-- confirmado con grep de "clear.*chat|vaciar.*chat|
-- delete_chat_history|clear_conversation" sin resultados en todo el
-- repo. Las cuatro apps de referencia dejan "Vaciar conversación": el
-- historial desaparece de TU vista, la otra persona sigue viendo todo
-- con normalidad, y los mensajes NUEVOS que lleguen después de vaciar
-- SÍ deben verse (a diferencia de "eliminar para mí" mensaje por
-- mensaje, aquí hace falta una fecha de corte real, no una lista).
--
-- Diseño real: tabla propia `chat_cleared_at` (una fila por persona por
-- chat, no una columna en `chats` -- mismo criterio ya usado por
-- `recent_searches`/`hashtag_follows`: preferencia puramente personal,
-- RLS solo-propio, sin necesitar que la otra persona del chat sepa
-- nada). El filtrado real (`created_at > cleared_before`) se resuelve
-- en el CLIENTE al listar mensajes -- mismo criterio exacto ya
-- documentado en 0118 para `deleted_for`: es una preferencia de "qué no
-- pintar", nunca una condición de seguridad real, así que no toca RLS
-- de `messages` en absoluto.
-- ============================================================================

create table chat_cleared_at (
    user_id uuid not null references profiles(id) on delete cascade,
    chat_id uuid not null references chats(id) on delete cascade,
    cleared_before timestamptz not null default now(),
    primary key (user_id, chat_id)
);

alter table chat_cleared_at enable row level security;

-- Cada quien gestiona solo su propia fecha de corte -- nunca la de la
-- otra persona del chat.
create policy chat_cleared_at_own on chat_cleared_at
    for all
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));
