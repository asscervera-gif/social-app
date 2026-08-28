-- ============================================================================
-- SOCIAL — Texto alternativo real (accesibilidad) en imágenes de posts,
-- comparado con Instagram/Facebook/Twitter-X
--
-- Confirmado que no existe ninguna implementación de texto alternativo:
-- grep de "alt_text|altText" sobre supabase/migrations/*.sql y ambos
-- clientes no devuelve nada. Las tres apps de referencia dejan describir
-- una foto para que lectores de pantalla (VoiceOver/TalkBack) la lean en
-- vez de decir solo "imagen" -- hueco real de accesibilidad, no solo de
-- producto.
--
-- Diseño real: `posts.alt_text` describe la PRIMERA foto (media_url,
-- mismo criterio ya usado por 0055_post_media.sql: media_url es
-- siempre la primera/única); `post_media.alt_text` describe cada foto
-- adicional por separado, porque cada una es una imagen real distinta
-- y merece su propia descripción -- una sola frase para un carrusel
-- entero no sería una descripción real y honesta de cada foto. Sin RLS
-- nueva: ambas tablas ya tienen su propia RLS (posts_write_own,
-- 0002_rls.sql; post_media hereda visibilidad de comments_select,
-- 0055) que ya cubre estas columnas nuevas sin cambios.
-- ============================================================================

alter table posts add column alt_text text check (alt_text is null or char_length(alt_text) <= 1000);
alter table post_media add column alt_text text check (alt_text is null or char_length(alt_text) <= 1000);
