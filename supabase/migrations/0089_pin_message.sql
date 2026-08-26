-- ============================================================================
-- SOCIAL — Fijar un mensaje en un chat, comparado con WhatsApp/Telegram
--
-- Las dos dejan fijar un mensaje real (propio o ajeno) para que aparezca
-- destacado arriba del chat, VISIBLE PARA TODOS los participantes -- a
-- diferencia de los mensajes destacados reales de 0087_starred_messages.sql
-- (totalmente privados, solo quien los destaca los ve). Confirmado en el
-- propio código: `grep` de "pinned_message"/"is_pinned_message" en todo
-- el repo no encontró nada -- el único "fijar" que existía era el de
-- CHATS enteros en la lista (0081_pin_chats.sql), nunca de un mensaje
-- concreto dentro de un chat ya abierto.
--
-- Diseño real: columnas en el propio mensaje (`pinned_at`/`pinned_by`),
-- no en `chats`/`group_chats` -- evita tener que validar con un trigger
-- aparte que una referencia cruzada (`chats.pinned_message_id`) apunte de
-- verdad a un mensaje de ESE chat. Alcance deliberado: el servidor no
-- impone "solo uno a la vez" -- el propio cliente desfija el anterior
-- antes de fijar uno nuevo (dos escrituras seguidas), mismo criterio de
-- "el cliente orquesta, el servidor solo protege identidad" ya aplicado
-- varias veces esta sesión.
--
-- Cualquiera de los participantes reales puede fijar/desfijar, no solo el
-- remitente (mismo criterio que WhatsApp/Telegram) -- por eso hace falta
-- una política de UPDATE nueva y más amplia que `messages_update_own`/
-- `group_messages_update_own` (solo el remitente). Postgres combina
-- varias políticas permisivas del mismo comando con OR A NIVEL DE FILA,
-- no de columna (mismo hallazgo real de seguridad ya documentado en
-- 0049_messages_edit.sql) -- sin ampliar también los triggers de
-- protección ya existentes, esta política nueva reabriría el mismo hueco
-- que 0049 cerró: un participante que NO es el remitente podría colar un
-- cambio de body/media_url/audio_url/edited_at aprovechando esta vía.
-- ============================================================================

alter table messages add column pinned_at timestamptz;
alter table messages add column pinned_by uuid references profiles(id) on delete set null;
alter table group_messages add column pinned_at timestamptz;
alter table group_messages add column pinned_by uuid references profiles(id) on delete set null;

create policy messages_update_pin on messages
    for update
    using (
        exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    )
    with check (
        exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );

create policy group_messages_update_pin on group_messages
    for update
    using (private.is_group_member(group_messages.group_chat_id, (select auth.uid())))
    with check (private.is_group_member(group_messages.group_chat_id, (select auth.uid())));

-- Extiende protect_message_columns (0049) en el sitio: además de proteger
-- body/media_url/audio_url/edited_at/read_at frente a la vía ya existente
-- (messages_update_read/messages_update_own), ahora también frente a la
-- NUEVA vía messages_update_pin -- (select auth.uid()) <> old.sender_id ya
-- es verdad para CUALQUIER participante que no sea el remitente, así que
-- el bloque ya existente cubre esa parte sin cambios; solo hace falta
-- añadir el guardado real de pinned_at/pinned_by (que pinned_by sea de
-- verdad quien pide el cambio, nunca una identidad ajena).
create or replace function private.protect_message_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if (
        new.body is distinct from old.body
        or new.media_url is distinct from old.media_url
        or new.audio_url is distinct from old.audio_url
        or new.edited_at is distinct from old.edited_at
    ) and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.media_url := old.media_url;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;
    if new.read_at is distinct from old.read_at
        and (select auth.uid()) = old.sender_id and current_user <> 'postgres' then
        new.read_at := old.read_at;
    end if;
    if new.pinned_at is not null and new.pinned_by is distinct from (select auth.uid()) and current_user <> 'postgres' then
        new.pinned_at := old.pinned_at;
        new.pinned_by := old.pinned_by;
    end if;
    return new;
end;
$$;

-- Mismo motivo exacto, aplicado a protect_group_message_identity (0065):
-- sin extenderlo, group_messages_update_pin (cualquier miembro real, no
-- solo el remitente) reabriría el mismo hueco de OR a nivel de fila.
create or replace function private.protect_group_message_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if current_user <> 'postgres' then
        new.group_chat_id := old.group_chat_id;
        new.sender_id := old.sender_id;
        new.created_at := old.created_at;
    end if;
    if (
        new.body is distinct from old.body
        or new.media_url is distinct from old.media_url
        or new.audio_url is distinct from old.audio_url
        or new.edited_at is distinct from old.edited_at
    ) and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.media_url := old.media_url;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;
    if new.pinned_at is not null and new.pinned_by is distinct from (select auth.uid()) and current_user <> 'postgres' then
        new.pinned_at := old.pinned_at;
        new.pinned_by := old.pinned_by;
    end if;
    return new;
end;
$$;
