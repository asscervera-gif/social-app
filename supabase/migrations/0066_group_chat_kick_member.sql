-- ============================================================================
-- SOCIAL — Expulsar a un miembro del grupo real, comparado con WhatsApp/
-- Messenger/Telegram: en las tres apps, quien creó el grupo (el "admin" de
-- SOCIAL, mismo rol ya usado en `group_chats_update_own`/renombrar-foto y
-- en el propio `notify_new_group_message`) puede quitar a otro miembro sin
-- esperar a que se vaya solo. `group_chat_members` (0057_group_chats.sql)
-- solo tenía `group_chat_members_delete_own` -- cada quien podía salir por
-- su cuenta, pero nadie podía sacar a otro, ni siquiera el creador.
--
-- Sin riesgo de recursión (la misma clase de bug que sí obligó a
-- `private.is_group_member` en 0057): esta política vive en
-- `group_chat_members` pero consulta `group_chats` (una tabla DISTINTA),
-- no se referencia a sí misma. `private.is_group_member` (que sí lee
-- `group_chat_members`) es `security definer`, así que evalúa sin pasar
-- por RLS -- no hay ciclo real aquí.
-- ============================================================================

create policy group_chat_members_delete_by_creator on group_chat_members
    for delete
    using (
        exists (
            select 1 from group_chats
            where group_chats.id = group_chat_members.group_chat_id
              and group_chats.created_by = (select auth.uid())
        )
    );
