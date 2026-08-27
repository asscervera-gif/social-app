-- ============================================================================
-- SOCIAL — El resultado de un duelo real por fin ajusta el % de
-- compatibilidad del chat, no solo la pantalla de resultado
--
-- Hallazgo real de integridad de producto (auditoría de los sistemas
-- diferenciales de SOCIAL frente a la competencia, no una comparación con
-- una app externa concreta): `duel-ai/index.ts` (`handleScoreDuel`) ya
-- inserta `compatibility_delta` en `duels` desde 0034/0035 (calculado por
-- la IA, protegido contra manipulación del cliente) -- pero ninguna
-- migración de las 108 anteriores conecta esa columna con
-- `chats.compatibility_score`. El número que de verdad se muestra en el
-- chat (`ChatScreen.kt`/`ChatView.swift`, "$compatibility% de
-- compatibilidad") solo se mueve con los votos manuales +1/+10/+100
-- (`compatibility_votes`, 0032) -- la promesa central del duelo ("ajusta
-- tu % real") era hasta ahora puramente cosmética: el delta se calcula,
-- se muestra una vez en `DuelResultScreen.kt`/`DuelResultView.swift`, y
-- nunca se acumula en ningún sitio.
--
-- Mismo patrón EXACTO que `private.apply_compatibility_vote` (0032): un
-- trigger AFTER INSERT en la tabla fuente de verdad (aquí `duels`, no
-- `compatibility_votes`) actualiza `chats.compatibility_score` con los
-- mismos límites 0-100. No hace falta ninguna comprobación de rol nueva:
-- `duels_insert` (0035) ya está revocada por completo salvo para
-- `service_role`, así que CUALQUIER fila de `duels` que llegue a
-- ejecutar este trigger ya viene, por construcción, de la Edge Function
-- real -- nunca del cliente. `protect_compatibility_score` (0032) ya
-- distingue con `pg_trigger_depth()` la escritura legítima en cascada
-- (>1, este trigger) de una escritura directa del cliente (<=1, seguiría
-- revertida): mismo mecanismo, ninguna migración adicional necesaria ahí.
--
-- Aviso de alcance deliberado, documentado también aquí: `duels.
-- completed_at` sigue sin usarse en ningún sitio (la fila se inserta ya
-- completa de un tirón, sin un estado "en curso" real) -- columna muerta
-- preexistente, ajena al hallazgo de esta migración, no se toca.
-- ============================================================================

create or replace function private.apply_duel_compatibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.compatibility_delta is not null then
        update public.chats
        set compatibility_score = greatest(0, least(100, compatibility_score + new.compatibility_delta))
        where id = new.chat_id;
    end if;
    return new;
end;
$$;

revoke execute on function private.apply_duel_compatibility() from public, anon, authenticated;

drop trigger if exists trg_apply_duel_compatibility on duels;
create trigger trg_apply_duel_compatibility
    after insert on duels
    for each row
    execute function private.apply_duel_compatibility();
