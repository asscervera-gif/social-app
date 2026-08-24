-- ============================================================================
-- SOCIAL — Fase 2: Row Level Security
--
-- Reglas de producto exigidas:
--   1. Secciones privadas del perfil solo visibles con social aceptado.
--   2. Posts marcados is_social_only solo para socials aceptados.
--   3. Ubicación solo consultable si location_public = true.
--   4. Compatibilidad solo visible si compat_public = true o hay solicitud aceptada.
--
-- Siguiendo las buenas prácticas de Supabase: auth.uid() envuelto en SELECT
-- (se cachea, no se llama por fila) y funciones security definer en el
-- esquema `private` para los checks que cruzan tablas.
-- ============================================================================

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- Función auxiliar: ¿existe un social aceptado entre A y B?
-- security definer + search_path vacío + revoke de ejecución directa,
-- según la regla de seguridad de RLS de Supabase.
-- ---------------------------------------------------------------------------
create or replace function private.has_accepted_social(a uuid, b uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.socials
    where status = 'accepted'
      and ((requester_id = a and addressee_id = b)
        or (requester_id = b and addressee_id = a))
  );
$$;

revoke execute on function private.has_accepted_social(uuid, uuid) from public, anon, authenticated;
grant execute on function private.has_accepted_social(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Función auxiliar: ¿hay una solicitud de compatibilidad aceptada de "viewer" hacia "owner"?
-- ---------------------------------------------------------------------------
create or replace function private.has_accepted_compat_request(viewer uuid, owner uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.compat_requests
    where requester_id = viewer and target_id = owner and status = 'accepted'
  );
$$;

revoke execute on function private.has_accepted_compat_request(uuid, uuid) from public, anon, authenticated;
grant execute on function private.has_accepted_compat_request(uuid, uuid) to authenticated, service_role;

-- ============================================================================
-- profiles
-- ============================================================================
alter table profiles enable row level security;

create index if not exists idx_profiles_id on profiles(id);

-- Soporta el filtro eq("is_invisible", false) que Match/Home (Android e
-- iOS) añadieron esta sesión al corregir el fallo de privacidad que traía
-- perfiles invisibles sin filtrar — sin este índice, esa consulta hace un
-- escaneo completo de la tabla a medida que crece. Parcial porque solo
-- interesa acelerar el caso "no invisible" (el filtro real de la consulta),
-- no el caso contrario.
create index if not exists idx_profiles_visible on profiles(id) where is_invisible = false;

create policy profiles_select_own on profiles
    for select
    using ((select auth.uid()) = id);

-- El resto de perfiles: visible siempre a nivel básico (nombre, avatar, intereses);
-- location_public/compat_public controlan campos concretos desde el cliente,
-- pero last_lat/last_lng solo se exponen si location_public es true.
create policy profiles_select_public on profiles
    for select
    using (
        (select auth.uid()) <> id
        and (location_public = true or last_lat is null)
    );

create policy profiles_update_own on profiles
    for update
    using ((select auth.uid()) = id)
    with check ((select auth.uid()) = id);

create policy profiles_insert_own on profiles
    for insert
    with check ((select auth.uid()) = id);

-- ============================================================================
-- profile_sections — regla 1: privadas solo con social aceptado
-- ============================================================================
alter table profile_sections enable row level security;

create index if not exists idx_profile_sections_owner on profile_sections(profile_id);

create policy profile_sections_select on profile_sections
    for select
    using (
        profile_id = (select auth.uid())
        or is_public = true
        or private.has_accepted_social((select auth.uid()), profile_id)
    );

create policy profile_sections_write_own on profile_sections
    for all
    using (profile_id = (select auth.uid()))
    with check (profile_id = (select auth.uid()));

-- ============================================================================
-- posts — regla 2: is_social_only solo para socials aceptados
-- ============================================================================
alter table posts enable row level security;

create index if not exists idx_posts_author_id on posts(author_id);

create policy posts_select on posts
    for select
    using (
        author_id = (select auth.uid())
        or is_social_only = false
        or private.has_accepted_social((select auth.uid()), author_id)
    );

create policy posts_write_own on posts
    for all
    using (author_id = (select auth.uid()))
    with check (author_id = (select auth.uid()));

-- ============================================================================
-- stories
-- ============================================================================
alter table stories enable row level security;

create index if not exists idx_stories_author_id on stories(author_id);

create policy stories_select on stories
    for select
    using (expires_at > now());

create policy stories_write_own on stories
    for all
    using (author_id = (select auth.uid()))
    with check (author_id = (select auth.uid()));

-- ============================================================================
-- follows
-- ============================================================================
alter table follows enable row level security;

create index if not exists idx_follows_follower on follows(follower_id);
create index if not exists idx_follows_followee on follows(followee_id);

create policy follows_select on follows
    for select
    using (true);

create policy follows_write_own on follows
    for all
    using (follower_id = (select auth.uid()))
    with check (follower_id = (select auth.uid()));

-- ============================================================================
-- socials
-- ============================================================================
alter table socials enable row level security;

create index if not exists idx_socials_requester on socials(requester_id);
create index if not exists idx_socials_addressee2 on socials(addressee_id);

create policy socials_select on socials
    for select
    using (requester_id = (select auth.uid()) or addressee_id = (select auth.uid()));

create policy socials_insert on socials
    for insert
    with check (requester_id = (select auth.uid()));

-- Solo el destinatario puede aceptar/rechazar (cambiar status).
create policy socials_update on socials
    for update
    using (addressee_id = (select auth.uid()))
    with check (addressee_id = (select auth.uid()));

-- ============================================================================
-- chats
-- ============================================================================
alter table chats enable row level security;

create index if not exists idx_chats_user_a on chats(user_a_id);
create index if not exists idx_chats_user_b on chats(user_b_id);

create policy chats_select on chats
    for select
    using (user_a_id = (select auth.uid()) or user_b_id = (select auth.uid()));

create policy chats_insert on chats
    for insert
    with check (user_a_id = (select auth.uid()) or user_b_id = (select auth.uid()));

-- Sin esta política, ChatViewModel.vote() (la barra de compatibilidad en
-- vivo, +1/+10/+100) nunca podría escribir compatibility_score en
-- producción real — con RLS activada y sin ninguna política de UPDATE,
-- Postgres deniega la operación por defecto, y el cliente ve el error
-- genérico "No se pudo registrar el voto." siempre, sin ninguna pista de
-- que el problema es del lado del servidor, no del cliente. Encontrado
-- auditando las políticas RLS de todas las tablas que el cliente escribe.
create policy chats_update on chats
    for update
    using (user_a_id = (select auth.uid()) or user_b_id = (select auth.uid()))
    with check (user_a_id = (select auth.uid()) or user_b_id = (select auth.uid()));

-- ============================================================================
-- messages
-- ============================================================================
alter table messages enable row level security;

create index if not exists idx_messages_chat_id on messages(chat_id);

create policy messages_select on messages
    for select
    using (
        exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );

create policy messages_insert on messages
    for insert
    with check (
        sender_id = (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = messages.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );

-- ============================================================================
-- compatibility_votes — regla 4: solo visible si compat_public o solicitud aceptada
-- ============================================================================
alter table compatibility_votes enable row level security;

create index if not exists idx_compat_votes_chat on compatibility_votes(chat_id);

create policy compatibility_votes_select on compatibility_votes
    for select
    using (
        exists (
            select 1 from chats
            where chats.id = compatibility_votes.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );

create policy compatibility_votes_insert on compatibility_votes
    for insert
    with check (
        voter_id = (select auth.uid())
        and exists (
            select 1 from chats
            where chats.id = compatibility_votes.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );

-- ============================================================================
-- profiles: exposición del % de compatibilidad agregado se resuelve en la app
-- mediante esta función, que respeta la regla 4 completa.
-- ============================================================================
create or replace function private.can_view_compatibility(viewer uuid, owner uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select
    viewer = owner
    or exists (select 1 from public.profiles where id = owner and compat_public = true)
    or private.has_accepted_compat_request(viewer, owner);
$$;

revoke execute on function private.can_view_compatibility(uuid, uuid) from public, anon, authenticated;
grant execute on function private.can_view_compatibility(uuid, uuid) to authenticated, service_role;

-- ============================================================================
-- duels
-- ============================================================================
alter table duels enable row level security;

create index if not exists idx_duels_chat on duels(chat_id);

create policy duels_select on duels
    for select
    using (
        initiator_id = (select auth.uid())
        or opponent_id = (select auth.uid())
        or is_public = true
    );

create policy duels_insert on duels
    for insert
    with check (initiator_id = (select auth.uid()));

create policy duels_update on duels
    for update
    using (initiator_id = (select auth.uid()) or opponent_id = (select auth.uid()))
    with check (initiator_id = (select auth.uid()) or opponent_id = (select auth.uid()));

-- ============================================================================
-- compat_requests
-- ============================================================================
alter table compat_requests enable row level security;

create index if not exists idx_compat_requests_requester on compat_requests(requester_id);
create index if not exists idx_compat_requests_target on compat_requests(target_id);

create policy compat_requests_select on compat_requests
    for select
    using (requester_id = (select auth.uid()) or target_id = (select auth.uid()));

create policy compat_requests_insert on compat_requests
    for insert
    with check (requester_id = (select auth.uid()));

create policy compat_requests_update on compat_requests
    for update
    using (target_id = (select auth.uid()))
    with check (target_id = (select auth.uid()));

-- ============================================================================
-- notifications
-- ============================================================================
alter table notifications enable row level security;

create index if not exists idx_notifications_recipient2 on notifications(recipient_id);

create policy notifications_select on notifications
    for select
    using (recipient_id = (select auth.uid()));

create policy notifications_update on notifications
    for update
    using (recipient_id = (select auth.uid()))
    with check (recipient_id = (select auth.uid()));

-- Las notificaciones las crea el backend (service_role) al reaccionar a eventos
-- (nuevo social, follow, fight, like, solicitud de %), no directamente el cliente.

-- ============================================================================
-- activities
-- ============================================================================
alter table activities enable row level security;

create index if not exists idx_activities_chat on activities(chat_id);

create policy activities_select on activities
    for select
    using (
        exists (
            select 1 from chats
            where chats.id = activities.chat_id
              and (chats.user_a_id = (select auth.uid()) or chats.user_b_id = (select auth.uid()))
        )
    );
