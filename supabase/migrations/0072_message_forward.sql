-- ============================================================================
-- SOCIAL — Reenviar un mensaje a otro chat real, comparado con WhatsApp/
-- Telegram/Messenger: en las tres apps, cualquier mensaje (propio o
-- ajeno) se puede reenviar a otro chat o grupo -- uno de los gestos de
-- mensajería más usados de esas apps, y SOCIAL no tenía ninguna forma de
-- hacerlo (ni siquiera copiar y pegar manualmente, dado que los mensajes
-- no tienen selección de texto real más allá del bubble completo).
--
-- `is_forwarded` (no `forwarded_from_message_id` ni ninguna referencia
-- real al mensaje original): mismo criterio simple que WhatsApp -- el
-- mensaje reenviado es una copia real e independiente de
-- body/media_url/audio_url, marcada con una etiqueta visual ("Reenviado"),
-- sin encadenar una cadena de referencias entre chats que el destinatario
-- del original podría no querer exponer (a quién se reenvió, cuántas
-- veces). Sin RLS nueva: sigue gobernado por `messages_insert`/
-- `group_messages_insert` normales, igual que cualquier mensaje nuevo --
-- reenviar no concede ningún permiso que el remitente no tuviera ya.
-- ============================================================================

alter table messages add column is_forwarded boolean not null default false;
alter table group_messages add column is_forwarded boolean not null default false;
