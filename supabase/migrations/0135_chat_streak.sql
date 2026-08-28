-- ============================================================================
-- SOCIAL — Racha de días consecutivos hablando en un chat 1:1, comparado
-- con Snapchat (Snapstreaks 🔥, una de las funciones que más engancha a
-- la retención diaria de esa app)
--
-- Hallazgo real, confirmado con `grep`: cero coincidencias de
-- "streak"/"racha" en todo el repo -- SOCIAL no tiene ningún concepto de
-- continuidad de conversación. `messages` (0001_schema.sql) ya tiene
-- `sender_id`/`chat_id`/`created_at`, así que no hace falta ninguna
-- tabla nueva -- basta una función real que cuente, sin traer el
-- historial completo al cliente solo para calcular esto.
--
-- Diseño real: una racha vale un día cuando AMBOS participantes del chat
-- escribieron al menos un mensaje real ese día (mismo criterio real que
-- Snapchat: hace falta que las DOS personas respondan, no solo una).
-- Alcance deliberado sobre "hoy": el bucle cuenta días consecutivos
-- ANTERIORES a hoy primero (la racha real ya asegurada, no se resetea a
-- las 00:00 solo porque nadie ha escrito todavía en las últimas horas),
-- y solo suma el día de hoy si YA se cumplió por las dos partes -- así
-- el número no "desaparece" en cuanto empieza el día y aún no ha
-- respondido nadie (comportamiento real de Snapchat: el streak sigue
-- visible durante el día hasta que de verdad se pierde a medianoche).
-- ============================================================================

create or replace function get_chat_streak(p_chat_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_other_id uuid;
  v_streak integer := 0;
  v_day date := current_date - 1;
  v_both boolean;
begin
  select case when user_a_id = v_uid then user_b_id else user_a_id end
    into v_other_id
  from public.chats
  where id = p_chat_id and (user_a_id = v_uid or user_b_id = v_uid);

  if v_other_id is null then
    return 0;
  end if;

  loop
    select
      exists(select 1 from public.messages where chat_id = p_chat_id and sender_id = v_uid and created_at::date = v_day)
      and exists(select 1 from public.messages where chat_id = p_chat_id and sender_id = v_other_id and created_at::date = v_day)
    into v_both;

    exit when not v_both;
    v_streak := v_streak + 1;
    v_day := v_day - 1;
  end loop;

  if exists(select 1 from public.messages where chat_id = p_chat_id and sender_id = v_uid and created_at::date = current_date)
     and exists(select 1 from public.messages where chat_id = p_chat_id and sender_id = v_other_id and created_at::date = current_date)
  then
    v_streak := v_streak + 1;
  end if;

  return v_streak;
end;
$$;

revoke execute on function get_chat_streak(uuid) from public, anon;
grant execute on function get_chat_streak(uuid) to authenticated;
