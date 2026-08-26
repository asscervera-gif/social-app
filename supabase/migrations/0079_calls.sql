-- ============================================================================
-- SOCIAL — Videollamada/llamada de voz 1:1 real desde un chat, comparado
-- con WhatsApp/Messenger/Instagram
--
-- Las tres dejan llamar (voz o vídeo) directamente desde un chat privado
-- -- mensajería sin llamada es la excepción hoy, no la norma. Confirmado
-- en el propio código: `grep` de "calls"/"video_call"/"voice_call" en
-- todo el repo no encontró NADA -- la única pieza de vídeo en tiempo real
-- que existe es "En directo" (0056_live_streams.sql), pensada para
-- audiencia PÚBLICA (host + N espectadores), sin ningún concepto de
-- sesión privada 1:1.
--
-- Reutiliza LiveKit (ya integrado en ambas plataformas desde "En
-- directo", mismo motor, misma cuenta) en vez de montar infraestructura
-- de señalización nueva: cada llamada real es una sala LiveKit propia
-- (`room_name` único), y esta tabla es la fuente de verdad de quién puede
-- pedir un token real para esa sala concreta (ver call-token/index.ts) --
-- mismo patrón exacto que live_streams/live-token.
-- ============================================================================

create table calls (
    id uuid primary key default uuid_generate_v4(),
    chat_id uuid not null references chats(id) on delete cascade,
    caller_id uuid not null references profiles(id) on delete cascade,
    callee_id uuid not null references profiles(id) on delete cascade,
    kind text not null check (kind in ('audio', 'video')),
    -- Mismo criterio que live_streams.room_name: nombre de sala propio,
    -- no reutiliza el uuid de la fila.
    room_name text not null unique default ('social-call-' || uuid_generate_v4()::text),
    status text not null default 'ringing' check (status in ('ringing', 'accepted', 'declined', 'ended', 'missed')),
    created_at timestamptz not null default now(),
    ended_at timestamptz,
    check (caller_id <> callee_id)
);

create index if not exists idx_calls_callee on calls(callee_id, status);
create index if not exists idx_calls_caller on calls(caller_id, status);

alter table calls enable row level security;

-- Solo los dos participantes reales de la llamada -- ni siquiera el otro
-- miembro del chat si por lo que sea hubiera más de dos (no los hay,
-- `chats` es siempre 1:1, pero la comprobación es explícita, no heredada).
create policy calls_select on calls
    for select
    using (caller_id = (select auth.uid()) or callee_id = (select auth.uid()));

-- El emisor real tiene que ser uno de los dos lados reales del chat
-- (`chats.user_a_id`/`user_b_id`), y el otro lado el destinatario real --
-- mismo criterio que trg_protect_group_message_identity: no basta con
-- confiar en lo que mande el cliente, se comprueba contra la fila real de
-- `chats`. Bloqueo real comprobado con private.is_blocked, mismo criterio
-- que live_stream_viewers_insert_own/comment_likes: llamar es una
-- interacción sobre la disponibilidad de otra persona.
create policy calls_insert on calls
    for insert
    with check (
        caller_id = (select auth.uid())
        and not private.is_blocked(caller_id, callee_id)
        and exists (
            select 1 from chats
            where chats.id = calls.chat_id
              and (
                  (chats.user_a_id = calls.caller_id and chats.user_b_id = calls.callee_id)
                  or (chats.user_a_id = calls.callee_id and chats.user_b_id = calls.caller_id)
              )
        )
    );

-- El destinatario real acepta/rechaza; cualquiera de los dos cuelga
-- (status='ended') o marca la propia llamada como perdida tras un
-- timeout real del lado del cliente que llama.
create policy calls_update on calls
    for update
    using (caller_id = (select auth.uid()) or callee_id = (select auth.uid()))
    with check (caller_id = (select auth.uid()) or callee_id = (select auth.uid()));

-- Protege la identidad real de la llamada (quién llama, a quién, desde
-- qué chat, con qué sala) frente a un UPDATE que intentara redirigirla --
-- mismo patrón exacto que trg_protect_group_message_identity/
-- trg_protect_group_chat_member_identity (pg_trigger_depth() <= 1, deja
-- pasar solo `status`/`ended_at`, que son las únicas columnas que de
-- verdad hace falta poder cambiar tras crear la fila).
create or replace function private.protect_call_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if pg_trigger_depth() <= 1 then
        new.chat_id := old.chat_id;
        new.caller_id := old.caller_id;
        new.callee_id := old.callee_id;
        new.kind := old.kind;
        new.room_name := old.room_name;
        new.created_at := old.created_at;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_call_identity() from public, anon, authenticated;

drop trigger if exists trg_protect_call_identity on calls;
create trigger trg_protect_call_identity
    before update on calls
    for each row execute function private.protect_call_identity();
