-- ============================================================================
-- SOCIAL — Fijar una publicación en el perfil (hasta 3), comparado con
-- Instagram
--
-- Instagram real deja fijar hasta TRES publicaciones propias para que
-- aparezcan siempre primero en la rejilla del perfil, sin importar
-- cuándo se publicaron -- distinto de "Fijar mensaje" (0089, un chat) o
-- "Fijar comentario" (0084, un comentario): aquí lo que se fija es la
-- propia publicación, en el sitio real donde vive la rejilla de
-- "Tus publicaciones". Confirmado en el propio código: `posts` no tenía
-- ningún concepto de orden manual -- siempre estrictamente por fecha.
--
-- Diseño real: una única columna `pinned_at` (el momento real en que se
-- fijó, no solo un booleano -- deja ordenar varias publicaciones
-- fijadas por cuándo se fijó cada una, mismo criterio real que
-- `pinned_at` en 0089_pin_message.sql). Sin política de UPDATE nueva:
-- `posts_write_own` (0002_rls.sql) ya es "for all", así que el propio
-- autor ya podía tocar cualquier columna de su publicación -- el límite
-- real de tres viene de un trigger nuevo, no de RLS (RLS decide QUIÉN
-- puede escribir, nunca CUÁNTAS filas cumplen una condición a la vez).
-- ============================================================================

alter table posts add column pinned_at timestamptz;

create or replace function private.limit_pinned_posts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pinned_count integer;
begin
  select count(*) into v_pinned_count
  from public.posts
  where author_id = new.author_id and pinned_at is not null and id <> new.id;

  if v_pinned_count >= 3 then
    raise exception 'Ya tienes 3 publicaciones fijadas -- quita una antes de fijar otra';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_limit_pinned_posts on posts;
create trigger trg_limit_pinned_posts
    before update on posts
    for each row
    when (new.pinned_at is not null and old.pinned_at is null)
    execute function private.limit_pinned_posts();
