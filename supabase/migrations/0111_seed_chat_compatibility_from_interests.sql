-- ============================================================================
-- SOCIAL — El % de compatibilidad de un chat nuevo arranca de verdad
-- desde los intereses compartidos, no de un 50 fijo para todo el mundo
--
-- Quinto hallazgo de la auditoría de sistemas propios de SOCIAL (%
-- compatibilidad): hay dos "compatibilidades" reales en la app que nunca
-- convergían -- (a) `estimatedCompatibility()` en el cliente (Jaccard
-- real sobre `profiles.interests`), usada para ordenar/mostrar tarjetas
-- en descubrimiento (Home/Match); (b) `chats.compatibility_score`, el
-- número "oficial" que vive en el chat una vez aceptado el social, que
-- arrancaba SIEMPRE en 50 (`0001_schema.sql`) sin importar el % estimado
-- real que llevó a esa persona a aceptar. Un usuario podía ver "92%" en
-- la tarjeta de Match y, al abrir el chat, encontrarse arrancando en
-- 50% -- inconsistencia real de producto, no cosmética.
--
-- Hallazgo de seguridad real encontrado al diseñar esta migración (no
-- simulado): auditando `chats_insert` (0002_rls.sql) para ver qué
-- necesitaba esta migración, `with check (user_a_id = auth.uid() or
-- user_b_id = auth.uid())` NUNCA restringió qué columnas puede fijar el
-- propio INSERT -- RLS es por FILA, no por columna, mismo mecanismo real
-- ya encontrado varias veces esta sesión (0029/0030/0032). A diferencia
-- de `chats.compatibility_score` en UPDATE (protegido desde 0032 por
-- `protect_compatibility_score`), NINGÚN trigger vigilaba el INSERT: un
-- cliente modificado podía insertar directamente `compatibility_score:
-- 100` al crear el chat, sin haber intercambiado ni un solo mensaje ni
-- voto real. `SocialLinkManager.getOrCreateChat()` (ambas plataformas)
-- nunca envía ese campo hoy -- así que este hueco no afectaba a nadie
-- usando el cliente oficial -- pero seguía siendo una vía real abierta.
--
-- Una sola solución cierra ambos hallazgos: un trigger BEFORE INSERT
-- calcula el % real (mismo Jaccard exacto que estimatedCompatibility(),
-- intersección/unión de `interests`) y SOBRESCRIBE `new.compatibility_score`
-- sea lo que sea que el cliente haya mandado -- igual que
-- `protect_compatibility_score` hace en UPDATE, pero para el INSERT.
-- Sin intereses compartidos que comparar (unión vacía, cualquiera de los
-- dos perfiles sin intereses todavía), se conserva el 50 de siempre --
-- mismo criterio real que el propio cliente, que devuelve `null` (sin
-- estimación) en ese caso.
-- ============================================================================

create or replace function private.seed_chat_compatibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    a_interests text[];
    b_interests text[];
    intersection_count integer;
    union_count integer;
begin
    select interests into a_interests from public.profiles where id = new.user_a_id;
    select interests into b_interests from public.profiles where id = new.user_b_id;

    if a_interests is null or b_interests is null
       or array_length(a_interests, 1) is null or array_length(b_interests, 1) is null then
        new.compatibility_score := 50;
        return new;
    end if;

    select count(*) into intersection_count from unnest(a_interests) x where x = any(b_interests);
    select count(*) into union_count from (select unnest(a_interests) union select unnest(b_interests)) u;

    if union_count = 0 then
        new.compatibility_score := 50;
    else
        new.compatibility_score := floor((intersection_count::numeric / union_count) * 100)::integer;
    end if;
    return new;
end;
$$;

revoke execute on function private.seed_chat_compatibility() from public, anon, authenticated;

drop trigger if exists trg_seed_chat_compatibility on chats;
create trigger trg_seed_chat_compatibility
    before insert on chats
    for each row
    execute function private.seed_chat_compatibility();
