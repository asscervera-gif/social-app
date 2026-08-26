-- ============================================================================
-- SOCIAL — Enviar una publicación a un chat real, comparado con
-- Instagram/TikTok/Twitter/Snapchat: en las cuatro apps, el icono de
-- "enviar" (➤) de una publicación abre un selector interno de a quién
-- mandársela (un DM, un grupo) -- es, con diferencia, el mecanismo de
-- distribución más usado de esas apps, más que el "compartir" externo al
-- sistema. En SOCIAL, ese mismo icono ➤ en `HomeScreen.kt`/`HomeView.swift`
-- solo abre el share sheet nativo del sistema operativo (texto plano hacia
-- otra app) -- no existe ninguna forma de mandar una publicación como
-- mensaje real dentro de la propia app, ni al chat 1:1 ni a un grupo.
--
-- `shared_post_id` nullable, `on delete set null` (mismo criterio ya
-- establecido para `reports.post_id`/`message_id`/`group_message_id`: si
-- la publicación se borra después de compartirse, el mensaje sigue
-- existiendo en el historial del chat, solo pierde la vista previa).
--
-- Sin RLS nueva: un mensaje con `shared_post_id` sigue gobernado por
-- `messages_insert`/`group_messages_insert` normales (mismo criterio que
-- media_url/audio_url, que tampoco tienen su propia comprobación de
-- propiedad) -- la visibilidad REAL de la publicación en sí la sigue
-- decidiendo `posts_select` cuando el destinatario intente verla, no esta
-- columna. Igual que compartir un enlace roto en cualquier app grande: se
-- puede mandar la referencia, pero solo se puede abrir si de verdad se
-- tiene permiso.
-- ============================================================================

alter table messages add column shared_post_id uuid references posts(id) on delete set null;
alter table messages drop constraint if exists messages_has_content;
alter table messages add constraint messages_has_content
    check (body is not null or media_url is not null or audio_url is not null or shared_post_id is not null);

alter table group_messages add column shared_post_id uuid references posts(id) on delete set null;
alter table group_messages drop constraint if exists group_messages_has_content;
alter table group_messages add constraint group_messages_has_content
    check (body is not null or media_url is not null or audio_url is not null or shared_post_id is not null);
