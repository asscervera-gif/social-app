-- ============================================================================
-- SOCIAL — Insignia de cumpleaños real (🎂) en el perfil, comparado con
-- Instagram/Facebook
--
-- Confirmado que no existe ningún rastro de fecha de nacimiento en todo
-- el repo: grep de "cumplea|birth_date|fecha_nacimiento" sobre
-- supabase/migrations/*.sql y ambos clientes no devuelve nada. Instagram
-- muestra una insignia de tarta en el perfil/historia el día del
-- cumpleaños; Facebook además manda un recordatorio. Esta ronda cubre
-- solo la insignia visual (Instagram), no el recordatorio con aviso
-- (Facebook) -- ver más abajo por qué, alcance deliberadamente acotado.
--
-- Diseño real: SIN pg_cron ni ningún trabajo en segundo plano -- mismo
-- criterio ya usado en `my_ban_status`/`muted_until_a/b` (0037/0082): la
-- condición "¿es hoy?" se calcula en el momento de leer, comparando
-- mes+día de `birth_date` contra la fecha real de hoy, nunca escrita de
-- vuelta a ningún sitio. `show_birthday` es un interruptor de privacidad
-- real (por defecto activado, igual que el resto de campos públicos del
-- perfil) -- si está desactivado, ni siquiera se calcula la insignia
-- para otros, mismo criterio que `location_updated_at`/`last_lat` ya
-- ocultos tras sus propios interruptores existentes.
-- ============================================================================

alter table profiles add column birth_date date;
alter table profiles add column show_birthday boolean not null default true;

-- Hallazgo real MÁS grave de esta ronda: `birth_date` ya se le pide al
-- usuario en AMBOS clientes al registrarse (AuthScreen.kt/AuthView.swift)
-- para la verificación real de "mayor de 18" (ver 0014_handle_new_user.sql
-- y el comentario de AuthViewModel.kt/.swift sobre por qué existe esa
-- comprobación) -- pero ese valor se usa solo para calcular la edad en el
-- momento y se DESCARTA, nunca viaja a `signUpWith(Email) { data = ... }`
-- ni se guarda en ningún sitio. `handle_new_user()` (0014) ya toma
-- `display_name` de `raw_user_meta_data`; se amplía aquí para tomar
-- `birth_date` del mismo sitio en cuanto el cliente empiece a mandarlo.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, birth_date)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'display_name',
      nullif(split_part(new.email, '@', 1), ''),
      'Nuevo usuario'
    ),
    nullif(new.raw_user_meta_data->>'birth_date', '')::date
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Calcula si es el cumpleaños real de un perfil HOY, respetando su
-- interruptor de privacidad -- sin cron, sin notificación, se llama
-- directamente desde el cliente al pintar el perfil/la fila del chat.
-- security invoker (por defecto): corre con los privilegios reales de
-- quien llama, así que profiles_select ya decide si puede ver la fila.
create or replace function public.is_birthday_today(p_profile_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
    select coalesce(
        (
            select p.show_birthday
                and extract(month from p.birth_date) = extract(month from current_date)
                and extract(day from p.birth_date) = extract(day from current_date)
            from public.profiles p
            where p.id = p_profile_id
        ),
        false
    );
$$;

revoke all on function public.is_birthday_today(uuid) from public;
grant execute on function public.is_birthday_today(uuid) to authenticated;
