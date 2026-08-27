-- ============================================================================
-- SOCIAL — Mensajes que desaparecen real también en el chat de GRUPO,
-- comparado con WhatsApp/Instagram DM ("Modo desvanecimiento")
--
-- 0115_disappearing_messages.sql dejó documentado como alcance
-- deliberado: "solo chat 1:1 en esta ronda... group_messages se deja
-- para una ronda futura aparte". Mismo diseño exacto, extendido a grupo:
-- `group_chats.disappearing_seconds` (mismos tres valores reales que
-- WhatsApp: 24h/7 días/90 días), `group_messages.disappear_at` calculado
-- SIEMPRE en el servidor (trigger BEFORE INSERT, ignora cualquier valor
-- que mande el cliente), inmutable después para cualquiera.
--
-- Diferencia real deliberada frente al 1:1: en el chat 1:1
-- `chats_update` (0002_rls.sql) ya dejaba a CUALQUIERA de los dos
-- participantes tocar el ajuste compartido -- en el chat de grupo NO
-- existe ninguna política de UPDATE abierta a "cualquier miembro" (a
-- diferencia del 1:1, solo hay dos personas y ambas son "el chat");
-- `group_chats_update_own`/`group_chats_update_by_admin` (0057/0108) ya
-- limitan quién puede tocar el grupo a su creador o a un admin. En vez
-- de abrir una tercera política permisiva nueva para "cualquier
-- miembro" (que reabriría el mismo riesgo real de robo de `created_by`
-- ya documentado en 0108), este ajuste se restringe a quien ya puede
-- tocar el grupo: creador o admin -- sin política nueva, sin guardia
-- nueva, reutilizando las dos políticas de UPDATE ya existentes tal
-- cual (protect_group_chat_identity, 0108, ya solo protege
-- created_by/created_at, disappearing_seconds queda libre igual que
-- name/photo_url).
--
-- `group_messages_select` (última versión real: 0057, confirmado con
-- grep en todas las migraciones) se extiende para excluir un mensaje ya
-- caducado, mismo mecanismo que `messages_select` (0115).
-- `protect_group_message_identity` (última versión real: 0121,
-- confirmado con grep) se extiende para que `disappear_at` sea
-- inmutable tras el envío.
--
-- Aviso de honestidad, mismo criterio ya reconocido en 0115: un mensaje
-- caducado se OCULTA vía RLS en cuanto se vuelve a consultar, nunca se
-- borra de verdad de la base de datos.
-- ============================================================================

alter table group_chats add column disappearing_seconds integer;
alter table group_chats add constraint group_chats_disappearing_seconds_valid
    check (disappearing_seconds is null or disappearing_seconds in (86400, 604800, 7776000));

alter table group_messages add column disappear_at timestamptz;

create or replace function private.set_group_message_disappear_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_seconds integer;
begin
    select disappearing_seconds into v_seconds from public.group_chats where id = new.group_chat_id;
    if v_seconds is not null then
        new.disappear_at := now() + make_interval(secs => v_seconds);
    else
        new.disappear_at := null;
    end if;
    return new;
end;
$$;

revoke execute on function private.set_group_message_disappear_at() from public, anon, authenticated;

drop trigger if exists trg_set_group_message_disappear_at on group_messages;
create trigger trg_set_group_message_disappear_at
    before insert on group_messages
    for each row
    execute function private.set_group_message_disappear_at();

drop policy if exists group_messages_select on group_messages;
create policy group_messages_select on group_messages
    for select
    using (
        private.is_group_member(group_messages.group_chat_id, (select auth.uid()))
        and (disappear_at is null or disappear_at > now())
    );

create or replace function private.protect_group_message_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
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
    ) and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.body := old.body;
        new.media_url := old.media_url;
        new.audio_url := old.audio_url;
        new.edited_at := old.edited_at;
    end if;
    if new.pinned_at is not null and new.pinned_by is distinct from v_uid and current_user <> 'postgres' then
        new.pinned_at := old.pinned_at;
        new.pinned_by := old.pinned_by;
    end if;

    if new.deleted_for is distinct from old.deleted_for and current_user <> 'postgres' then
        if not (old.deleted_for <@ new.deleted_for)
           or not (new.deleted_for <@ (old.deleted_for || v_uid))
        then
            new.deleted_for := old.deleted_for;
        end if;
    end if;

    if new.is_video is distinct from old.is_video
        and v_uid <> old.sender_id and current_user <> 'postgres' then
        new.is_video := old.is_video;
    end if;

    -- Mensajes que desaparecen (0124): disappear_at lo fija SIEMPRE el
    -- trigger de INSERT -- inmutable después para cualquiera, mismo
    -- criterio real que messages.disappear_at (0115).
    if new.disappear_at is distinct from old.disappear_at and current_user <> 'postgres' then
        new.disappear_at := old.disappear_at;
    end if;

    return new;
end;
$$;
