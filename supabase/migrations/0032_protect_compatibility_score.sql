-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo de seguridad real — compatibility_score
-- escribible directamente por el cliente
--
-- Mismo hallazgo, misma familia que `is_verified` (0029) y `social_count`
-- (0030): `chats_update` (0002_rls.sql) solo comprueba que el usuario sea
-- parte del chat, RLS es por FILA no por COLUMNA — `ChatViewModel.kt/
-- .swift.vote()` calculaba `newScore` EN EL CLIENTE y lo escribía
-- directamente con `.update({ compatibility_score: newScore })`. Un
-- cliente modificado podía saltarse el voto por completo y mandar
-- `compatibility_score = 100` sin ningún `compatibility_votes` real
-- detrás, o con un delta que no corresponde al enviado.
--
-- Solución de dos partes:
-- 1. El servidor calcula el nuevo score: un trigger AFTER INSERT en
--    `compatibility_votes` (la fuente de verdad real de cada voto)
--    actualiza `chats.compatibility_score`, sujeto a los mismos límites
--    0-100 que ya tenía el cálculo del cliente.
-- 2. `chats.compatibility_score` se protege igual que `is_verified`: un
--    trigger BEFORE UPDATE revierte cualquier cambio directo salvo que
--    venga de `service_role` (que es justamente lo que hace el trigger
--    del punto 1, al ejecutarse como `security definer`).
-- El cliente ya no necesita escribir `chats` directamente — sigue viendo
-- el número actualizado en vivo vía la suscripción Realtime a `UPDATE` en
-- `chats` que ya existía (ChatViewModel.kt/.swift.subscribeToRealtime).
-- ============================================================================

create or replace function private.apply_compatibility_vote()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.chats
    set compatibility_score = greatest(0, least(100, compatibility_score + new.delta))
    where id = new.chat_id;
    return new;
end;
$$;

revoke execute on function private.apply_compatibility_vote() from public, anon, authenticated;

drop trigger if exists trg_apply_compatibility_vote on compatibility_votes;
create trigger trg_apply_compatibility_vote
    after insert on compatibility_votes
    for each row
    execute function private.apply_compatibility_vote();

-- Aviso importante sobre por qué esto usa `pg_trigger_depth()` y no
-- `auth.role() <> 'service_role'` (como sí hace correctamente
-- `protect_is_verified` en 0029, donde el escritor de confianza es una
-- llamada API real con clave `service_role`): aquí el escritor de
-- confianza es el propio trigger de este archivo
-- (`apply_compatibility_vote`), que se ejecuta DENTRO de la misma sesión
-- que originó el voto — `auth.role()` seguiría devolviendo
-- 'authenticated' en ese momento, así que esa comprobación revertiría
-- también la actualización legítima. `pg_trigger_depth()` sí distingue
-- correctamente: 1 = la propia sentencia UPDATE del cliente (bloquear),
-- >1 = disparado en cascada desde otro trigger, en este caso desde el
-- INSERT en `compatibility_votes` (permitir).
create or replace function private.protect_compatibility_score()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.compatibility_score <> old.compatibility_score and pg_trigger_depth() <= 1 then
        new.compatibility_score := old.compatibility_score;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_compatibility_score() from public, anon, authenticated;

drop trigger if exists trg_protect_compatibility_score on chats;
create trigger trg_protect_compatibility_score
    before update on chats
    for each row
    execute function private.protect_compatibility_score();
