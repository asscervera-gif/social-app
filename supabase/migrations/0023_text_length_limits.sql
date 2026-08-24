-- ============================================================================
-- SOCIAL — Fase 9: límites de longitud reales en campos de texto
--
-- Hallazgo real: `comments.body` ya tenía un límite (1-500 caracteres,
-- 0008_comments.sql), pero `messages.body`, `posts.caption`,
-- `profiles.display_name`/`bio` nunca lo tuvieron — un cliente modificado
-- (o un bug) podía insertar texto de tamaño arbitrario, rompiendo el
-- renderizado de burbujas de chat/tarjetas de post y desperdiciando
-- almacenamiento sin ningún límite real. Límites generosos pero reales,
-- no arbitrariamente estrictos: mensajes de chat pueden ser más largos
-- que un comentario, un caption de post más largo aún (mismo orden de
-- magnitud que Instagram, ~2200).
-- ============================================================================

alter table messages add constraint messages_body_length
    check (body is null or char_length(body) between 1 and 2000);

alter table posts add constraint posts_caption_length
    check (caption is null or char_length(caption) <= 2200);

alter table profiles add constraint profiles_display_name_length
    check (char_length(display_name) between 1 and 50);

alter table profiles add constraint profiles_bio_length
    check (bio is null or char_length(bio) <= 300);
