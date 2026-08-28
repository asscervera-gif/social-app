-- ============================================================================
-- SOCIAL — Texto sobre la Historia + @menciones reales ahí, comparado
-- con Instagram/TikTok/Snapchat
--
-- Confirmado que `stories` (0001_schema.sql) no tiene ninguna columna de
-- texto -- solo `media_url`. El sistema de menciones ya existe para
-- posts/reels/comments/reel_comments (0074_mentions.sql), pero nunca se
-- extendió a historias porque éstas ni siquiera soportaban texto
-- superpuesto. Instagram/TikTok/Snapchat dejan escribir texto sobre la
-- foto/vídeo de una historia y mencionar a @alguien ahí, con aviso real.
--
-- Alcance deliberadamente acotado, mismo criterio que 0074: solo texto
-- simple + detección de @usuario vía la función ya existente
-- (private.extract_mentioned_profile_ids) -- sin stickers arrastrables
-- ni posicionamiento libre en pantalla (eso seguiría necesitando un
-- editor visual real, fuera de alcance aquí). `'mention'` ya está
-- permitido en notifications_kind_check desde 0074, no hace falta
-- tocarlo.
-- ============================================================================

alter table stories add column caption text;
alter table stories add constraint stories_caption_length
    check (caption is null or char_length(caption) <= 2200);

create or replace function private.notify_mentions_in_story()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mentioned_id uuid;
begin
  for v_mentioned_id in select * from private.extract_mentioned_profile_ids(new.caption, new.author_id)
  loop
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (v_mentioned_id, new.author_id, 'mention', jsonb_build_object('actor_id', new.author_id, 'story_id', new.id));
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_notify_mentions_in_story on stories;
create trigger trg_notify_mentions_in_story
  after insert on stories
  for each row execute function private.notify_mentions_in_story();
