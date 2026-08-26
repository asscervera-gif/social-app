-- ============================================================================
-- SOCIAL — Nombre editable y foto de grupo real, comparado con WhatsApp/
-- Messenger/Telegram: en las tres apps, un grupo se puede renombrar y se le
-- puede poner una foto DESPUÉS de crearlo. En SOCIAL (0057_group_chats.sql),
-- el nombre se fija una sola vez al crear el grupo (sin ninguna forma real
-- de cambiarlo después) y no existe columna de foto en absoluto -- confirmado
-- que la política `group_chats_update_own` (creado en 0057, pensada para
-- este caso) nunca llegó a usarse: cero `update`/`.update(` sobre
-- `group_chats` en todo el código cliente de ninguna plataforma.
--
-- Solo falta la columna de foto -- el nombre ya es una columna normal
-- (`name`), así que renombrar es un `update` directo sin cambio de esquema.
-- Sin cambio de RLS: `group_chats_update_own` (creado en 0057, `using
-- (created_by = auth.uid())`) ya cubre cualquier columna, foto incluida --
-- mismo criterio de "solo el creador" ya establecido en esa política (el
-- rol de "admin" de WhatsApp/Messenger, sin sistema de roles nuevo).
-- ============================================================================

alter table group_chats add column if not exists photo_url text;
