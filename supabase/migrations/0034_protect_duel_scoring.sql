-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo de seguridad real — resultado de
-- duelo falseable
--
-- Misma familia que 0029/0030/0032/0033: `duels_update` (0002_rls.sql)
-- solo comprueba que el usuario sea `initiator_id`/`opponent_id`, RLS por
-- fila no por columna. El cliente real (`DuelViewModel.kt/.swift`) nunca
-- escribe `compatibility_delta`/`explanation`/`answers` directamente — los
-- calcula la Edge Function `duel-ai` (`AnthropicDuelService.kt/.swift`,
-- clave `ANTHROPIC_API_KEY` en el servidor) y los escribe con
-- `service_role`, así que hasta ahora nada dependía de este hueco para
-- funcionar. Pero un cliente modificado SÍ podía escribir directamente
-- `compatibility_delta`/`explanation` sin pasar por la IA, falseando el
-- resultado que ve el propio usuario y su pareja de duelo en
-- `DuelResultScreen.kt`/`DuelResultView.swift`. Aquí el escritor de
-- confianza es una llamada API real con `service_role` (como
-- `is_verified` en 0029), no un trigger anidado — se usa `auth.role()`,
-- no `pg_trigger_depth()`.
-- ============================================================================

create or replace function private.protect_duel_scoring()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.role() <> 'service_role' then
        new.compatibility_delta := old.compatibility_delta;
        new.explanation := old.explanation;
        new.completed_at := old.completed_at;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_duel_scoring() from public, anon, authenticated;

drop trigger if exists trg_protect_duel_scoring on duels;
create trigger trg_protect_duel_scoring
    before update on duels
    for each row
    execute function private.protect_duel_scoring();
