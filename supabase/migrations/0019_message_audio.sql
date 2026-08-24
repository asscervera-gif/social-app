-- ============================================================================
-- SOCIAL — Fase 9: mensajes de voz (última pieza de "chat funcional con
-- fotos, voz, reacciones, read receipts" — fotos, read receipts y
-- reacciones ya resueltas en pasadas anteriores de esta sesión).
--
-- `audio_url` separado de `media_url` (no reutilizado): un mensaje de voz
-- no es una foto, y el cliente necesita distinguir cuál de los dos
-- renderizar (imagen vs. reproductor) sin adivinar por la extensión del
-- archivo — más explícito y más seguro que inferir el tipo de contenido.
-- ============================================================================

alter table messages add column if not exists audio_url text;

alter table messages drop constraint if exists messages_body_or_media;
alter table messages add constraint messages_has_content
    check (body is not null or media_url is not null or audio_url is not null);
