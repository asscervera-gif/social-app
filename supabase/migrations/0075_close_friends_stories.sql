-- ============================================================================
-- SOCIAL — "Mejores amigos" (audiencia privada para historias), comparado
-- con Instagram (Close Friends) y Snapchat (audiencia personalizada)
--
-- Hallazgo real de seguridad, no solo de funcionalidad: `stories_select`
-- (0002_rls.sql) es `using (expires_at > now())` -- SIN ninguna
-- restricción de audiencia. Cualquier usuario autenticado puede ver la
-- historia de CUALQUIER otro, sin necesidad de social aceptado ni de
-- seguirle -- ni siquiera existe el equivalente de `posts.is_social_only`
-- para historias. Instagram/Snapchat dejan reducir la audiencia de una
-- historia concreta a una lista privada de "mejores amigos"; SOCIAL no
-- tenía ningún concepto de audiencia en absoluto para historias.
-- ============================================================================

create table close_friends (
    owner_id uuid not null references profiles(id) on delete cascade,
    friend_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (owner_id, friend_id),
    check (owner_id <> friend_id)
);

create index if not exists idx_close_friends_owner on close_friends(owner_id);

alter table close_friends enable row level security;

-- Mismo criterio que Instagram: ni siquiera la persona añadida puede ver
-- que está en la lista de otra persona -- solo el propio dueño ve/gestiona
-- su lista.
create policy close_friends_select_own on close_friends
    for select
    using (owner_id = (select auth.uid()));

create policy close_friends_insert_own on close_friends
    for insert
    with check (owner_id = (select auth.uid()));

create policy close_friends_delete_own on close_friends
    for delete
    using (owner_id = (select auth.uid()));

-- Mismo patrón exacto que private.is_blocked/private.has_accepted_social
-- (security definer + search_path vacío + revoke de ejecución directa):
-- hace falta porque `stories_select` (más abajo) tiene que comprobar la
-- lista de OTRO usuario (el autor de la historia), algo que
-- close_friends_select_own no deja leer directamente.
create or replace function private.is_close_friend(owner uuid, friend uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.close_friends
    where close_friends.owner_id = owner and close_friends.friend_id = friend
  );
$$;

revoke execute on function private.is_close_friend(uuid, uuid) from public, anon, authenticated;
grant execute on function private.is_close_friend(uuid, uuid) to authenticated, service_role;

-- Audiencia real por historia -- 'everyone' (comportamiento actual, por
-- defecto real de las ya existentes) o 'close_friends' (solo la lista
-- privada del autor, más el propio autor).
alter table stories add column visibility text not null default 'everyone';
alter table stories add constraint stories_visibility_check
    check (visibility in ('everyone', 'close_friends'));

drop policy if exists stories_select on stories;
create policy stories_select on stories
    for select
    using (
        expires_at > now()
        and (
            visibility = 'everyone'
            or author_id = (select auth.uid())
            or private.is_close_friend(author_id, (select auth.uid()))
        )
    );
