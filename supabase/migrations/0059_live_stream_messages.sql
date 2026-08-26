-- ============================================================================
-- SOCIAL — Chat en vivo durante un directo, comparado con Instagram/TikTok
-- Live: en las dos, el chat en vivo (comentarios que se desplazan sobre o
-- junto al vídeo) es LA función que hace interactivo un directo, no un
-- añadido -- 0056_live_streams.sql construyó el vídeo real (LiveKit) y el
-- contador de espectadores, pero ningún espectador podía escribir nada
-- mientras veía un directo, comparado con esas dos apps.
--
-- Mismo criterio de visibilidad que la propia `live_streams`: quien puede
-- VER el directo (host, público, o social aceptado con el host) puede LEER
-- su chat -- no hace falta estar en `live_stream_viewers` (evita el mismo
-- problema de recursión/timing ya encontrado con group_chat_members,
-- reutilizando directamente el criterio de visibilidad de la fila padre en
-- vez de otra tabla de pertenencia). Para ESCRIBIR, además de poder ver el
-- directo, hace falta no estar bloqueado por el host -- mismo criterio que
-- `live_stream_viewers_insert_own`.
-- ============================================================================

create table live_stream_messages (
    id uuid primary key default uuid_generate_v4(),
    stream_id uuid not null references live_streams(id) on delete cascade,
    sender_id uuid not null references profiles(id) on delete cascade,
    -- Mensajes de chat en vivo son cortos a propósito (mismo criterio que
    -- Instagram/TikTok Live, no un mensaje de chat privado largo).
    body text not null check (char_length(body) between 1 and 200),
    created_at timestamptz not null default now()
);

create index if not exists idx_live_stream_messages_stream on live_stream_messages(stream_id, created_at);

alter table live_stream_messages enable row level security;

create policy live_stream_messages_select on live_stream_messages
    for select
    using (
        exists (
            select 1 from live_streams
            where live_streams.id = live_stream_messages.stream_id
              and (
                  live_streams.host_id = (select auth.uid())
                  or live_streams.is_social_only = false
                  or private.has_accepted_social((select auth.uid()), live_streams.host_id)
              )
        )
    );

create policy live_stream_messages_insert on live_stream_messages
    for insert
    with check (
        sender_id = (select auth.uid())
        and exists (
            select 1 from live_streams
            where live_streams.id = live_stream_messages.stream_id
              and (
                  live_streams.host_id = (select auth.uid())
                  or live_streams.is_social_only = false
                  or private.has_accepted_social((select auth.uid()), live_streams.host_id)
              )
        )
        and not private.is_blocked(
            (select auth.uid()),
            (select host_id from live_streams where live_streams.id = live_stream_messages.stream_id)
        )
    );
