-- ---------------------------------------------------------------------------
-- HALLAZGO DE SEGURIDAD REAL, GRAVE, ACTIVO EN PRODUCCION -- encontrado
-- verificando la ronda de push notifications con el arnes real de pruebas
-- (test_rls.mjs), no con una auditoria manual. Reproducido primero con el
-- archivo de pruebas SIN MODIFICAR contra las migraciones ORIGINALES (antes
-- de cualquier cambio de esta pasada) para confirmar que no era una
-- regresion de hoy -- ya estaba roto desde 0039_fix_definer_elevation.sql.
--
-- 0039 anadio `current_user <> 'postgres'` a protect_ban_columns() para
-- distinguir "esta escritura viene de admin_ban_user (de confianza)" de
-- "esta escritura viene de un cliente directo (no de confianza)" -- la
-- idea era correcta (current_user SI pasa a ser 'postgres' dentro de una
-- funcion security definer propiedad de postgres, confirmado
-- empiricamente en su momento). El fallo: protect_ban_columns() en si
-- MISMA tambien esta declarada `security definer`. Una funcion trigger
-- security definer fija current_user a SU PROPIO dueno (postgres) durante
-- SU PROPIA ejecucion, sin importar que current_user tuviera la
-- sentencia UPDATE que la disparo -- asi que la comprobacion
-- `current_user <> 'postgres'` es SIEMPRE falsa DENTRO del propio
-- trigger, para CUALQUIER llamador, admin_ban_user o un cliente crudo.
-- Resultado real: protect_ban_columns() dejo de revertir NADA desde que
-- se aplico 0039 -- cualquier usuario autenticado podia hacer
-- `update profiles set is_banned = false where id = auth.uid()` y
-- autodesbanearse, sin pasar nunca por admin_ban_user. Confirmado con una
-- prueba de RLS real (test_rls.mjs, nueva comprobacion
-- "protect_ban_columns"), no solo con lectura del SQL.
--
-- Por que verify_remote_ban.mjs (pasada anterior) no lo detecto: solo
-- probaba el camino "admin_ban_user SI banea" (el que sigue funcionando
-- igual, porque el trigger siendo un no-op permisivo no le afecta a ese
-- camino) -- nunca probo el camino "un usuario normal NO puede
-- autodesbanearse", que es justo la mitad que se rompio.
--
-- Arreglo real: quitar `security definer` del propio TRIGGER (no hace
-- falta -- ya tiene REVOKE EXECUTE de public/anon/authenticated, que
-- impide llamarla directo por SQL; ejecutarse como trigger no necesita
-- ese privilegio). Sin security definer, current_user dentro del cuerpo
-- del trigger vuelve a reflejar el contexto real de quien disparo el
-- UPDATE -- 'postgres' cuando lo dispara admin_ban_user (una funcion
-- security definer, de confianza), el rol real del cliente en cualquier
-- otro caso. Mismo patron que protect_is_admin()/protect_is_verified(),
-- que nunca tuvieron este problema porque nunca anadieron el chequeo de
-- current_user.
-- ---------------------------------------------------------------------------

create or replace function private.protect_ban_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if auth.role() <> 'service_role' and current_user <> 'postgres' then
        if new.is_banned <> old.is_banned then
            new.is_banned := old.is_banned;
        end if;
        if new.banned_until is distinct from old.banned_until then
            new.banned_until := old.banned_until;
        end if;
        if new.ban_reason is distinct from old.ban_reason then
            new.ban_reason := old.ban_reason;
        end if;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_ban_columns() from public, anon, authenticated;
