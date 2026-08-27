-- ============================================================================
-- SOCIAL — Etiqueta de ubicación real también en un reel, comparado con
-- Instagram/TikTok
--
-- Las dos dejan etiquetar un nombre de sitio real en un vídeo corto,
-- exactamente igual que en una foto -- `0095_post_location_tag.sql` ya
-- construyó esta función completa para `posts`, pero `reels` se quedó
-- fuera: confirmado en el propio código, `reels` no tiene ninguna
-- columna de ubicación.
--
-- Mismo diseño EXACTO que 0095: texto libre (sin geocodificación ni API
-- de sitios real, mismo aviso de honestidad ya documentado allí), mismo
-- límite real de 100 caracteres, sin política ni trigger nuevos
-- (`reels_write_own`, 0050, ya deja al autor tocar cualquier columna
-- propia sin restricción -- mismo criterio ya aplicado a
-- `hide_like_count`/`is_sensitive`/`reply_audience` en `reels`).
-- ============================================================================

alter table reels add column location_name text;
alter table reels add constraint reels_location_name_length check (location_name is null or char_length(location_name) <= 100);
