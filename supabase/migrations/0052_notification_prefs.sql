-- ============================================================================
-- SOCIAL — Preferencias de notificaciones push por categoría, comparado
-- con Instagram/Twitter/Facebook/WhatsApp: todas dejan silenciar "me
-- gusta" sin silenciar "mensajes", por ejemplo. Antes de esta migración,
-- `send-push` (Edge Function) enviaba SIEMPRE, para cualquier `kind`, sin
-- ninguna forma de que el usuario apagara una categoría concreta -- el
-- único control existente era silenciar un CHAT completo
-- (0047_message_notify_mute.sql), no un TIPO de aviso en toda la app.
--
-- Columna simple en `profiles` (no una tabla aparte): el conjunto de
-- `kind` que el usuario ha silenciado, mismos valores exactos que
-- `notifications.kind` (0001/0008/0046/0047/0050). Sin trigger de
-- protección -- es una preferencia propia sin implicaciones de seguridad,
-- a diferencia de `is_admin`/`is_banned`, así que `profiles_update_own`
-- (0002_rls.sql) ya es suficiente.
-- ============================================================================

alter table profiles add column if not exists muted_push_kinds text[] not null default '{}';
