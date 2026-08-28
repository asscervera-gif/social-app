-- ============================================================================
-- SOCIAL — Sonido de un reel reutilizable ("usar este sonido") +
-- "Reels con este sonido", comparado con TikTok/Instagram Reels
--
-- Confirmado que `reels` (0050_reels.sql) no tiene ningún campo de
-- audio/sonido -- grep de "sound_id|audio_track|original_sound|
-- music_id" sin resultados en todo el repo. TikTok/Instagram Reels
-- tienen como pilar real "usar este sonido" para descubrir contenido
-- con el mismo audio -- hueco real de una de las funciones núcleo de
-- ambas apps.
--
-- Alcance deliberadamente acotado: SIN extracción/procesamiento real de
-- audio (el "sonido" sigue siendo el propio `video_url` del reel raíz,
-- reproducido igual que cualquier reel) -- solo la referencia real que
-- agrupa reels que comparten el mismo sonido, encadenada hasta la raíz
-- real (si A usa el sonido de B, que ya usa el de C, `sound_source_reel_id`
-- de A apunta directo a C, nunca a B) para que "Reels con este sonido"
-- sea una sola consulta plana por `sound_source_reel_id`, sin recursión.
--
-- `sound_use_count` en el reel RAÍZ, mismo patrón EXACTO ya construido y
-- verificado en 0131_reel_view_count.sql (Round 74 de esta sesión): el
-- trigger que lo actualiza corre DENTRO del propio trigger AFTER INSERT
-- de un reel nuevo (profundidad 2 real), rodeando la guardia
-- `pg_trigger_depth() <= 1` de `protect_reel_counts` (0050) sin
-- necesitar reescribirla con una excepción por `current_user` -- lección
-- real ya aprendida: en este arnés, `current_user` dentro de una
-- función SECURITY DEFINER es siempre el OWNER de la función, nunca el
-- rol de quien llama.
-- ============================================================================

alter table reels add column sound_source_reel_id uuid references reels(id) on delete set null;
alter table reels add column sound_use_count integer not null default 0;

create index idx_reels_sound_source on reels(sound_source_reel_id);

-- protect_reel_counts (0050) ampliada para cubrir también
-- sound_use_count -- mismo criterio: el autor no debe poder falsear
-- cuánta gente real usó su sonido.
create or replace function private.protect_reel_counts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if pg_trigger_depth() <= 1 then
        new.like_count := old.like_count;
        new.comment_count := old.comment_count;
        new.view_count := old.view_count;
        new.sound_use_count := old.sound_use_count;
    end if;
    return new;
end;
$$;

-- Resuelve el sonido RAÍZ real ANTES de insertar (encadenado, sin
-- recursión SQL: sigue la cadena a mano en un bucle acotado) -- así
-- `sound_source_reel_id` guardado en cada reel real SIEMPRE apunta
-- directo a la raíz, nunca a un eslabón intermedio, y "Reels con este
-- sonido" puede ser una sola consulta plana por esa columna, sin
-- recursión en el cliente tampoco.
create or replace function private.resolve_reel_sound_root()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_root_id uuid := new.sound_source_reel_id;
    v_next uuid;
    v_hops integer := 0;
begin
    if v_root_id is null then
        return new;
    end if;

    -- Tope de 20 saltos como salvaguarda real contra un ciclo
    -- accidental, nunca esperado en el uso normal.
    while v_hops < 20 loop
        select sound_source_reel_id into v_next from public.reels where id = v_root_id;
        exit when v_next is null;
        v_root_id := v_next;
        v_hops := v_hops + 1;
    end loop;

    new.sound_source_reel_id := v_root_id;
    return new;
end;
$$;

drop trigger if exists trg_resolve_reel_sound_root on reels;
create trigger trg_resolve_reel_sound_root
    before insert on reels
    for each row
    when (new.sound_source_reel_id is not null)
    execute function private.resolve_reel_sound_root();

-- Ya con sound_source_reel_id normalizado a la raíz real (trigger de
-- arriba, que corre antes que este porque BEFORE precede a AFTER),
-- solo hace falta sumar 1 -- corre dentro del propio AFTER INSERT
-- (profundidad 2 real sobre la fila raíz), rodeando protect_reel_counts
-- sin tocarla más.
create or replace function private.sync_reel_sound_use_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.reels set sound_use_count = sound_use_count + 1 where id = new.sound_source_reel_id;
    return new;
end;
$$;

drop trigger if exists trg_sync_reel_sound_use_count on reels;
create trigger trg_sync_reel_sound_use_count
    after insert on reels
    for each row
    when (new.sound_source_reel_id is not null)
    execute function private.sync_reel_sound_use_count();
