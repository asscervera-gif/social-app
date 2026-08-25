-- ============================================================================
-- SOCIAL — referencia real al mensaje de chat denunciado
--
-- Hallazgo real, comparado con Instagram/WhatsApp/Messenger: mismo hueco
-- exacto que 0045_reports_content_reference.sql (posts/comments), pero en
-- un chat. `ChatView.swift`/`ChatScreen.kt` ya dejaban denunciar a la otra
-- persona desde el chat (ronda anterior, icono junto a la barra de
-- compatibilidad) -- pero sin ninguna forma de apuntar a QUÉ mensaje
-- concreto motivó la denuncia, justo donde ocurre la mayoría del acoso
-- real en cualquier app de mensajería. `reports.details` es texto libre y
-- editable por el propio denunciante, no una referencia real.
--
-- `message_id` nullable, `on delete set null` (mismo criterio que
-- post_id/comment_id: si el mensaje se borra después de denunciarse, la
-- denuncia sigue existiendo para el historial de moderación, solo pierde
-- la referencia al mensaje ya inexistente).
--
-- Diferencia deliberada con 0045: `posts_select_admin`/`comments_select_admin`
-- son un bypass GENERAL para cualquier admin (cualquier post/comentario,
-- estén o no denunciados) -- razonable porque son publicaciones, contenido
-- ya semi-público dentro de la app. Un mensaje de chat es la superficie
-- MÁS privada de toda la app (una conversación 1 a 1 entre dos personas
-- que nunca eligieron exponerla a un tercero) -- replicar el mismo bypass
-- general aquí significaría que cualquier admin podría leer TODAS las
-- conversaciones privadas de TODOS los usuarios, denunciadas o no. En vez
-- de eso, `messages_select_admin` solo deja ver un mensaje que esté
-- REALMENTE referenciado por una fila de `reports` -- acotado al mínimo
-- necesario para poder moderar, mismo criterio que usan las apps grandes
-- (un moderador ve el mensaje reportado, no la conversación entera).
-- ============================================================================

alter table reports add column message_id uuid references messages(id) on delete set null;

create policy messages_select_admin on messages
    for select
    using (
        exists (select 1 from profiles where profiles.id = (select auth.uid()) and profiles.is_admin = true)
        and exists (select 1 from reports where reports.message_id = messages.id)
    );
