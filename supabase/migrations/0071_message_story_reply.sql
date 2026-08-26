-- ============================================================================
-- SOCIAL — Responder a una historia real, comparado con Instagram/WhatsApp
-- Status/Snapchat: en las tres apps, ver la historia de alguien muestra un
-- campo de texto abajo ("Responder..."); escribir y enviar manda esa
-- respuesta como un mensaje DIRECTO real a esa persona -- es, junto con
-- "quién vio tu historia" (ya real, 0053_story_views.sql), una de las dos
-- piezas de interacción con historias más usadas de esas apps. En SOCIAL,
-- `StoryViewer`/el visor de historias no tenía ningún campo de texto ni
-- forma de responder -- solo tocar para avanzar/retroceder y ver quién la
-- vio.
--
-- `story_id` nullable, `on delete set null` (mismo criterio ya establecido
-- para `shared_post_id`/`reports.post_id`/etc.): si la historia expira o
-- se borra después de responderse, el mensaje sigue existiendo en el
-- historial del chat, solo pierde la vista previa.
--
-- Sin RLS nueva a propósito: `stories_select` (0002_rls.sql) ya deniega
-- ver una historia caducada (`expires_at > now()`) incluso al destinatario
-- real del mensaje -- comportamiento CORRECTO y esperado (igual que
-- WhatsApp Status: si el estado ya expiró, la vista previa de "respondió a
-- tu estado" deja de poder mostrarse), no un hueco a tapar con una
-- política nueva. El cliente debe mostrar un respaldo real ("Historia ya
-- no disponible") si la consulta no devuelve nada, mismo criterio que
-- shared_post_id.
-- ============================================================================

alter table messages add column story_id uuid references stories(id) on delete set null;
alter table messages drop constraint if exists messages_has_content;
alter table messages add constraint messages_has_content
    check (body is not null or media_url is not null or audio_url is not null or shared_post_id is not null or story_id is not null);
