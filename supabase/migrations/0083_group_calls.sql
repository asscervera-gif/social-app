-- ============================================================================
-- SOCIAL — Videollamada de grupo real, comparado con WhatsApp/Messenger/
-- Telegram
--
-- Las tres dejan iniciar una llamada (voz o vídeo) con TODO un grupo desde
-- el propio chat de grupo, no solo 1:1. Confirmado en el propio código:
-- `calls` (0079_calls.sql) es estrictamente 1:1 -- `chat_id` referencia
-- `chats` (que a su vez SIEMPRE es 1:1, 0001_schema.sql) y `callee_id` es
-- una sola persona. Alcance deliberadamente aplazado en la propia
-- 0079_calls.sql: "llamadas de GRUPO quedan fuera de esta ronda... hueco
-- real futuro, no construido a medias".
--
-- Diseño: se AÑADE `group_chat_id` a `calls` (nullable) junto al
-- `chat_id`/`callee_id` ya existentes (ahora también nullable) -- una
-- llamada es 1:1 XOR de grupo, nunca las dos cosas, igual que
-- `posts`/`reels` distinguen su tipo de contenido con columnas nullable en
-- vez de dos tablas separadas. Como una llamada de grupo no tiene un único
-- "destinatario", hace falta una fila POR PARTICIPANTE (mismo criterio que
-- `group_chat_members` frente a `chats.user_a_id/user_b_id`): tabla nueva
-- `call_participants`, poblada automáticamente por trigger con todos los
-- miembros reales del grupo en el momento de crear la llamada (mismo
-- patrón de trigger que rellena `notifications` desde
-- `notify_new_group_message`, 0058).
--
-- Reutiliza `call-token`/LiveKit ya construidos (0079): una sala LiveKit
-- admite de sobra más de dos participantes sin ningún cambio de
-- infraestructura -- lo que faltaba era el modelo relacional y la
-- autorización para saber QUIÉN puede pedir un token para esa sala.
-- ============================================================================

alter table calls alter column chat_id drop not null;
alter table calls alter column callee_id drop not null;
alter table calls add column group_chat_id uuid references group_chats(id) on delete cascade;

-- Exactamente uno de los dos destinos reales -- nunca los dos ni ninguno.
alter table calls add constraint calls_target_check check (
    (chat_id is not null and group_chat_id is null and callee_id is not null)
    or (chat_id is null and group_chat_id is not null and callee_id is null)
);

create index if not exists idx_calls_group_chat on calls(group_chat_id, status);

-- Una fila por miembro real de la llamada de grupo -- mismo motivo que
-- group_chat_members frente a chats.user_a_id/user_b_id: no hay un único
-- "destinatario" al que apuntar.
create table call_participants (
    call_id uuid not null references calls(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    status text not null default 'ringing' check (status in ('ringing', 'accepted', 'declined', 'ended')),
    joined_at timestamptz,
    left_at timestamptz,
    primary key (call_id, user_id)
);

alter table call_participants enable row level security;

-- Mismo motivo exacto que private.is_group_member (0057_group_chats.sql,
-- documentado ahí con el error real de Postgres que dispara): un `exists`
-- inline contra la MISMA tabla que protege una política de esa tabla
-- lanza "infinite recursion detected in policy for relation
-- call_participants" -- una función security definer consulta sin pasar
-- por RLS, rompiendo el ciclo.
create or replace function private.is_call_participant(p_call_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
    select exists (
        select 1 from public.call_participants
        where call_participants.call_id = p_call_id and call_participants.user_id = p_user_id
    );
$$;

revoke execute on function private.is_call_participant(uuid, uuid) from public, anon, authenticated;
grant execute on function private.is_call_participant(uuid, uuid) to authenticated, service_role;

-- Cualquier participante real de la llamada ve a todos los demás
-- participantes (mismo criterio que group_chat_members_select: un miembro
-- ve al resto de miembros), no solo su propia fila.
create policy call_participants_select on call_participants
    for select
    using (private.is_call_participant(call_participants.call_id, (select auth.uid())));

-- Solo tu propia fila: aceptar/rechazar/colgar es una decisión personal,
-- nunca en nombre de otro participante. Sin política de INSERT: las filas
-- las crea únicamente el trigger security definer de más abajo, nunca el
-- cliente directamente.
create policy call_participants_update on call_participants
    for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

-- Rellena call_participants con todos los miembros reales del grupo en el
-- momento de crear la llamada -- el propio emisor entra ya 'accepted'
-- (está llamando, ya está "dentro"), el resto arranca 'ringing'. Mismo
-- patrón de trigger AFTER INSERT que notify_new_group_message (0058).
create or replace function private.populate_call_participants()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.group_chat_id is not null then
        insert into public.call_participants (call_id, user_id, status, joined_at)
        select
            new.id,
            gcm.user_id,
            case when gcm.user_id = new.caller_id then 'accepted' else 'ringing' end,
            case when gcm.user_id = new.caller_id then now() else null end
        from public.group_chat_members gcm
        where gcm.group_chat_id = new.group_chat_id;

        -- El estado global no depende de que el cliente lo mande bien --
        -- una llamada de grupo real ya está "en curso" en cuanto se crea
        -- (no hay un único destinatario que la acepte primero). UPDATE
        -- security definer, no pasa por RLS ni por protect_call_identity
        -- (que nunca toca `status`, a cualquier profundidad).
        update public.calls set status = 'accepted' where id = new.id;
    end if;
    return new;
end;
$$;

revoke execute on function private.populate_call_participants() from public, anon, authenticated;

drop trigger if exists trg_populate_call_participants on calls;
create trigger trg_populate_call_participants
    after insert on calls
    for each row execute function private.populate_call_participants();

-- calls_select ampliada: además de los dos lados de una llamada 1:1,
-- cualquier participante real de una llamada de grupo (vía
-- call_participants, ya poblada por el trigger de arriba en la misma
-- transacción del INSERT).
drop policy if exists calls_select on calls;
create policy calls_select on calls
    for select
    using (
        caller_id = (select auth.uid())
        or callee_id = (select auth.uid())
        or (group_chat_id is not null and private.is_call_participant(calls.id, (select auth.uid())))
    );

-- calls_insert ampliada: la rama 1:1 original sin cambios, más una rama de
-- grupo -- el emisor tiene que ser de verdad miembro real del grupo
-- (private.is_group_member, ya existente desde 0057_group_chats.sql). Una
-- llamada de grupo arranca ya 'accepted' a nivel de la fila global (no hay
-- un único "destinatario" que la acepte primero) -- cada participante
-- gestiona su propio ringing/accepted/declined en call_participants.
drop policy if exists calls_insert on calls;
create policy calls_insert on calls
    for insert
    with check (
        caller_id = (select auth.uid())
        and (
            (
                chat_id is not null and callee_id is not null
                and not private.is_blocked(caller_id, callee_id)
                and exists (
                    select 1 from chats
                    where chats.id = calls.chat_id
                      and (
                          (chats.user_a_id = calls.caller_id and chats.user_b_id = calls.callee_id)
                          or (chats.user_a_id = calls.callee_id and chats.user_b_id = calls.caller_id)
                      )
                )
            )
            or (
                group_chat_id is not null
                and private.is_group_member(calls.group_chat_id, caller_id)
            )
        )
    );

-- protect_call_identity (0079) ampliada para congelar también
-- group_chat_id -- create or replace en el sitio, mismo criterio ya usado
-- para extender protect_chat_muted_flags/notify_new_message en
-- 0082_mute_until.sql: no hace falta tocar el trigger en sí.
create or replace function private.protect_call_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if pg_trigger_depth() <= 1 then
        new.chat_id := old.chat_id;
        new.group_chat_id := old.group_chat_id;
        new.caller_id := old.caller_id;
        new.callee_id := old.callee_id;
        new.kind := old.kind;
        new.room_name := old.room_name;
        new.created_at := old.created_at;
    end if;
    return new;
end;
$$;
