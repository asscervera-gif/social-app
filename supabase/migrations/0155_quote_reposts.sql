-- ============================================================================
-- SOCIAL — Repost con comentario ("Quote Tweet"), comparado con Twitter/X
-- y Facebook ("Compartir con comentario")
--
-- `post_reposts` (0127_post_reposts.sql) ya guarda el repost "silencioso"
-- (sin contenido propio), como el Retweet simple. Confirmado con `grep`
-- de "quote_repost|quote_post|quotepost|quote_text" sin resultados en
-- todo el repo: falta la variante con texto propio que Twitter/X,
-- Facebook y hasta TikTok (dueto con comentario) sí tienen.
--
-- Diseño real: se reutiliza la MISMA tabla (`post_reposts`) en vez de
-- crear una nueva -- un repost simple es solo `quote_text is null`, y la
-- restricción `unique(post_id, user_id)` ya existente (una fila por
-- persona por post) sigue siendo exactamente el límite correcto: igual
-- que en Twitter/X, no tiene sentido citar el mismo post más de una vez
-- desde la misma cuenta. Las policies existentes (`post_reposts_select`/
-- `_insert_own`/`_delete_own`) ya cubren la columna nueva sin cambios,
-- porque no distinguen columnas.
-- ============================================================================

alter table post_reposts add column quote_text text
    check (char_length(quote_text) <= 500);

-- El trigger de aviso ya existente (private.notify_new_repost, 0127)
-- incluye ahora quote_text en el payload para que el cliente pueda
-- mostrar "citó tu publicación: ..." en vez de solo "reposteó tu
-- publicación" en la notificación, sin tocar el kind ('repost' sigue
-- sirviendo para ambos casos -- mismo criterio de no tocar
-- notifications_kind_check si no hace falta).
create or replace function private.notify_new_repost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select author_id into v_author_id from public.posts where id = new.post_id;
  if v_author_id is not null and v_author_id <> new.user_id then
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (
      v_author_id,
      new.user_id,
      'repost',
      jsonb_build_object('actor_id', new.user_id, 'post_id', new.post_id, 'quote_text', new.quote_text)
    );
  end if;
  return new;
end;
$$;
