-- ============================================================================
-- SOCIAL — Foto para ver una vez, comparado con WhatsApp/Instagram DM/
-- Snapchat
--
-- Las tres apps de referencia dejan mandar una foto que el destinatario
-- solo puede abrir UNA vez -- después desaparece de verdad, ni siquiera
-- volviendo a consultar el chat se puede ver otra vez. Confirmado en el
-- propio código: `messages.media_url` (0016) es una columna normal, sin
-- ningún concepto de "consumo" -- cualquier foto real del chat 1:1 se
-- podía volver a ver sin límite siempre.
--
-- Diseño real: `view_once` (fija en el envío, inmutable después) +
-- `opened_at` (null hasta que el destinatario real la abre). El propio
-- SERVIDOR vacía `media_url` en cuanto `opened_at` pasa de null a
-- no-null -- nunca el cliente decidiendo "ya no la vuelvo a pedir": un
-- destinatario técnico que reconsultara la fila directamente tampoco
-- podría recuperar la URL real después de abrirla, igual que WhatsApp
-- real borra el archivo de verdad, no solo lo oculta en pantalla.
--
-- Hallazgo real de seguridad, aprendido de 0049_messages_edit.sql (no
-- repetido, evitado a propósito): `messages_update_read` (0017) ya deja
-- a CUALQUIER destinatario hacer un UPDATE sobre la fila entera del
-- mensaje ajeno (su USING/WITH CHECK no restringe columnas) -- por eso
-- NO hace falta ninguna política de UPDATE nueva aquí, la extensión real
-- va en `protect_message_columns` (0049), la única guardia real de
-- columnas que ya existe. `view_once` se protege igual que
-- `body`/`audio_url`/`edited_at` (inmutable tras el envío, para
-- cualquiera que no sea el remitente); `opened_at` solo puede pasar de
-- null a no-null, y solo lo puede hacer real el destinatario (nunca el
-- propio remitente, mismo criterio real que `read_at`); `media_url` se
-- fuerza a null de verdad en esa transición exacta -- sin depender de
-- que el propio cliente la incluya en su UPDATE, precisamente para que
-- no haga falta confiar en él.
-- Alcance deliberado: solo el chat 1:1 por ahora, igual que el criterio
-- ya aplicado en 0102/0103 -- `group_messages` queda como hueco real
-- aparte, documentado en LOOP_STATE.md.
-- ============================================================================

alter table messages add column view_once boolean not null default false;
alter table messages add column opened_at timestamptz;
-- "not opened_at is not null" en vez de "not media_url is not null" a
-- secas: el propio trigger de más abajo vacía media_url de verdad en
-- cuanto se abre -- una restricción que exigiera media_url SIEMPRE que
-- view_once sea true chocaría con su propia consumición real (hallazgo
-- real, encontrado ejecutando el test de esta misma migración: la
-- primera versión sí lo exigía siempre, y abrir la foto real violaba la
-- restricción de un tirón).
alter table messages add constraint messages_view_once_needs_media
    check (not view_once or opened_at is not null or media_url is not null);

-- Segundo hallazgo real, encontrado en el mismo test: una foto real "para
-- ver una vez" SIN texto (el caso normal, igual que WhatsApp/Snapchat)
-- solo tenía media_url como contenido real -- en cuanto el trigger de
-- abajo la vacía de verdad al abrirla, la fila deja de cumplir
-- `messages_has_content` (0071: exige AL MENOS un campo de contenido
-- real) y la propia apertura legítima se rechaza de un tirón. Igual que
-- `messages_view_once_needs_media` de arriba, la solución real es
-- reconocer que una foto YA consumida no necesita ningún contenido --
-- ese es precisamente el punto de la función.
alter table messages drop constraint if exists messages_has_content;
alter table messages add constraint messages_has_content
    check (
        body is not null or media_url is not null or audio_url is not null
        or shared_post_id is not null or story_id is not null or view_once
    );

create or replace function private.protect_message_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_is_view_once_consumption boolean;
begin
    v_is_view_once_consumption := old.view_once
        and old.opened_at is null
        and new.opened_at is not null
        and (select auth.uid()) <> old.sender_id;

    if (
        new.body is distinct from old.body
        or new.audio_url is distinct from old.audio_url
        or new.edited_at is distinct from old.edited_at
    ) and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;

    if v_is_view_once_consumption then
        new.media_url := null;
    elsif new.media_url is distinct from old.media_url
        and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.media_url := old.media_url;
    end if;

    if new.read_at is distinct from old.read_at
        and (select auth.uid()) = old.sender_id and current_user <> 'postgres' then
        new.read_at := old.read_at;
    end if;

    -- Fijar un mensaje real (0089_pin_message.sql) -- guardia YA
    -- existente, reincorporada aquí letra por letra al extender esta
    -- misma función (aviso de proceso: la primera versión de esta
    -- migración la perdió por accidente al partir de la versión de
    -- 0049 en vez de la más reciente de 0089, confirmado con una
    -- regresión real en el test ya existente de "Fijar un mensaje").
    if new.pinned_at is not null and new.pinned_by is distinct from (select auth.uid()) and current_user <> 'postgres' then
        new.pinned_at := old.pinned_at;
        new.pinned_by := old.pinned_by;
    end if;

    -- Foto para ver una vez (0105_view_once_messages.sql): view_once es
    -- inmutable tras el envío real, para cualquiera que no sea el
    -- remitente -- mismo criterio exacto que body/audio_url/edited_at.
    if new.view_once is distinct from old.view_once
        and (select auth.uid()) <> old.sender_id and current_user <> 'postgres' then
        new.view_once := old.view_once;
    end if;

    -- opened_at solo puede pasar de null a no-null, y solo lo puede
    -- hacer real el destinatario (nunca el propio remitente) -- mismo
    -- criterio real que read_at, pero además irreversible una vez fijado.
    if new.opened_at is distinct from old.opened_at
        and not v_is_view_once_consumption
        and current_user <> 'postgres' then
        new.opened_at := old.opened_at;
    end if;

    return new;
end;
$$;
