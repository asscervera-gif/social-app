-- ============================================================================
-- SOCIAL — "Hace X min" real en la ubicación de Find, comparado con
-- Snapchat Map ("Active Xh ago"/"Just now", pines "ghost" para ubicación
-- vieja) y Find My de Apple ("Ubicación actualizada hace X min")
--
-- Hallazgo real: `profiles.last_lat`/`last_lng` (0001_schema.sql) no
-- tienen ninguna columna de fecha asociada -- `PrivacySettingsViewModel.kt`/
-- `.swift` escriben ambas coordenadas sin escribir nunca CUÁNDO. Una vez
-- publicada, la ubicación pública queda "congelada" para siempre en el
-- mapa de Find sin que nadie pueda saber si es real ahora mismo o de
-- hace semanas -- confirmado con `grep`: cero coincidencias de
-- "location_updated_at"/columna de fecha de ubicación en todo el repo.
-- ============================================================================

alter table profiles add column location_updated_at timestamptz;
