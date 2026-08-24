-- ============================================================================
-- SOCIAL — Fase 8: crear `profiles` automáticamente al registrarse
--
-- Hallazgo real (ya documentado en LOOP_STATE.md > Pendiente real): no
-- existía ningún trigger `on_auth_user_created`/`handle_new_user` en
-- Postgres, ni ningún `insert` a `profiles` en el código cliente de
-- ninguna plataforma. Aunque alguien se registrara en Supabase Auth
-- directamente, no tendría fila en `profiles` y cualquier feature con FK a
-- esa tabla fallaría (comprobado: `profiles.id` es FK a `auth.users(id)`,
-- pero nada la rellena). Esto es la pieza de esquema del hueco raíz de
-- "no existe flujo de registro" — no resuelve el onboarding completo
-- (selfie/consentimiento/avatar sigue sin UI, ver LOOP_STATE.md), pero sí
-- resuelve la parte que puede romper el resto de la app en cuanto exista
-- cualquier pantalla de registro real: sin esto, esa pantalla futura
-- necesitaría reinventar esta lógica en el cliente, con doble riesgo de
-- carrera (insert de perfil vs. insert de otras filas con FK a profiles).
--
-- `display_name` es NOT NULL en 0001_schema.sql — se deriva de
-- `raw_user_meta_data->>'display_name'` si el flujo de registro lo manda
-- (patrón estándar de Supabase Auth signUp con `data: {...}`), si no del
-- prefijo del email, y si no hay email tampoco (login solo por teléfono,
-- por ejemplo) un valor por defecto seguro.
-- ============================================================================

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'display_name',
      nullif(split_part(new.email, '@', 1), ''),
      'Nuevo usuario'
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function private.handle_new_user();
