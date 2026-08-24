-- ============================================================================
-- SOCIAL — Fase 9: fotos en el chat (primera pieza de "chat multimedia")
--
-- Hallazgo: `messages` solo tenía `body text` — el chat solo soportaba
-- texto, documentado toda la sesión como bloqueado por falta de Storage.
-- Storage ya existe (ver 0015_storage.sql), así que se cierra la parte de
-- fotos ahora. Voz/reacciones/read receipts siguen pendientes (necesitan
-- grabación de audio nativa y más decisiones de diseño, no solo Storage).
--
-- `media_url` opcional, igual que `posts.media_url` — pero un mensaje
-- necesita AL MENOS texto o foto, nunca ninguno de los dos (a diferencia
-- de un post, donde una publicación sin nada no tendría sentido enviarla
-- de todas formas, pero aquí si se permitiera un mensaje totalmente vacío
-- sería directamente un bug de UI, no un caso de uso real).
-- ============================================================================

alter table messages add column if not exists media_url text;

alter table messages add constraint messages_body_or_media
    check (body is not null or media_url is not null);
