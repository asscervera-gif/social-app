-- ============================================================================
-- SOCIAL — Cooldown real entre votos de compatibilidad, sexto hallazgo
-- de la auditoría de sistemas propios de SOCIAL (% de compatibilidad)
--
-- `compatibility_votes_insert` (0002/0027) nunca tuvo ningún límite de
-- frecuencia real -- a diferencia del ÚNICO otro mecanismo real de
-- ajustar el % (el duelo con IA, acotado a ±15 por sesión de 5
-- preguntas Y a 20 duelos/hora vía `ai_usage`), cualquiera de los dos
-- lados de un chat podía pulsar "+100" repetidamente sin ningún freno
-- real y llevar el score a 100% en segundos. El % en vivo, tal como
-- estaba, no tenía ninguna garantía real de reflejar nada -- el propio
-- mecanismo "serio" (duelo) queda en los hechos por debajo en rigor del
-- mecanismo "casual" (voto directo).
--
-- Mismo criterio de diseño ya usado en el resto de la sesión para un
-- freno real de frecuencia (0004_ai_usage.sql: comprobar una ventana de
-- tiempo real contra filas ya existentes) pero resuelto aquí en la
-- propia política RLS -- sin tabla nueva, sin Edge Function nueva --
-- porque `compatibility_votes` ya es, en sí misma, la fuente de verdad
-- completa de "cuándo votó quién por última vez": no hace falta llevar
-- la cuenta en ningún otro sitio.
--
-- 30 segundos entre votos reales de la MISMA persona en el MISMO chat:
-- suficiente para frenar un "mantener pulsado" o una ráfaga de toques
-- reales, sin frenar una conversación real normal (nada exige votar más
-- de una vez cada 30s con la otra persona todavía delante de la
-- pantalla). No afecta a la otra persona del chat, que puede seguir
-- votando con su propio cooldown independiente.
--
-- Hallazgo real encontrado ejecutando el test de esta misma migración
-- (no simulado): la primera versión de esta política comprobaba el
-- cooldown con un `exists` normal contra `compatibility_votes` -- LA
-- MISMA tabla que la propia política protege -- y Postgres lo rechazó
-- de un tirón con "infinite recursion detected in policy for relation
-- compatibility_votes". Mismo mecanismo real ya documentado varias
-- veces esta sesión para `group_chats`/`group_chat_members`
-- (`private.is_group_admin`) y `posts`/`profiles`
-- (`private.has_accepted_social`): una política de una tabla no puede
-- consultar la MISMA tabla con un `exists` normal sin ciclo -- la
-- solución real, ya establecida en este código, es siempre un helper
-- `security definer`, nunca inlinear la subconsulta.
-- ============================================================================

create or replace function private.recently_voted_compatibility(target_chat_id uuid, target_voter_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
    select exists (
        select 1 from public.compatibility_votes
        where chat_id = target_chat_id
          and voter_id = target_voter_id
          and created_at > now() - interval '30 seconds'
    );
$$;

revoke execute on function private.recently_voted_compatibility(uuid, uuid) from public, anon, authenticated;
grant execute on function private.recently_voted_compatibility(uuid, uuid) to authenticated;

drop policy if exists compatibility_votes_insert on compatibility_votes;
create policy compatibility_votes_insert on compatibility_votes
    for insert
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = compatibility_votes.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
        and not private.is_blocked(
            (select auth.uid()),
            (select case when chats.user_a_id = (select auth.uid()) then chats.user_b_id else chats.user_a_id end
             from chats where chats.id = compatibility_votes.chat_id)
        )
        and not private.recently_voted_compatibility(compatibility_votes.chat_id, (select auth.uid()))
    );
