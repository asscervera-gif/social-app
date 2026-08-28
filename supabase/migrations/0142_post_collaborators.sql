-- ============================================================================
-- SOCIAL — Publicación colaborativa real ("Collab"), comparado con
-- Instagram (Collabs, desde 2021)
--
-- Confirmado que `posts` (0001_schema.sql) solo tiene `author_id uuid not
-- null` -- un único autor posible. Grep de
-- "collaborator|co_author|coauthor|collab" sobre supabase/migrations/*.sql
-- no devuelve nada. Instagram deja invitar a una segunda cuenta como
-- coautora real de una publicación (con su consentimiento explícito,
-- nunca automático) -- hueco real, ausente por completo aquí.
--
-- Diseño real: tabla nueva `post_collaborators` en vez de una segunda
-- columna en `posts`, porque la invitación necesita un estado real
-- (pendiente/aceptada/rechazada) que una columna `co_author_id` sola no
-- puede representar sin inventar valores mágicos. Mismo patrón de
-- "invitación con estado" ya usado en `socials`/`compat_requests`.
--
-- Trigger de identidad: mismo criterio exacto que
-- `protect_group_chat_member_identity` (0064) -- la política de UPDATE
-- de más abajo (necesariamente amplia, para que el invitado pueda
-- aceptar/rechazar) dejaría a cualquiera reescribir `post_id`/`user_id`
-- de su propia fila sin el trigger, "trasladando" su respuesta a otra
-- invitación/publicación distinta.
--
-- Alcance deliberadamente acotado esta ronda: solo el mecanismo real de
-- invitar/aceptar/rechazar + el aviso correspondiente. Mostrar la
-- publicación colaborativa en la cuadrícula de perfil del INVITADO (el
-- otro medio real de Instagram Collabs) queda como hueco futuro
-- documentado, no fingido aquí -- tocar cada sitio donde el cliente
-- consulta `posts` por `author_id` (editar/borrar/fijar/etc., varios en
-- MyPostsScreen.kt) es un cambio bastante más grande y arriesgado para
-- esta pasada.
-- ============================================================================

create table post_collaborators (
    post_id uuid not null references posts(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
    invited_at timestamptz not null default now(),
    responded_at timestamptz,
    primary key (post_id, user_id)
);

alter table post_collaborators enable row level security;

create index idx_post_collaborators_user_id on post_collaborators(user_id);

-- El autor real del post ve/crea sus propias invitaciones; el invitado
-- ve/responde las suyas -- mismo criterio de "cada quien ve lo suyo" ya
-- usado en `socials`/`compat_requests`.
create policy post_collaborators_select on post_collaborators
    for select
    using (
        user_id = (select auth.uid())
        or post_id in (select id from posts where author_id = (select auth.uid()))
    );

-- Solo el autor real del post puede invitar (comprobado contra `posts`,
-- no confiar en un author_id suelto en el payload).
create policy post_collaborators_insert on post_collaborators
    for insert
    with check (
        status = 'pending'
        and post_id in (select id from posts where author_id = (select auth.uid()))
    );

-- Amplia a propósito (el invitado necesita poder tocar su propia fila
-- para aceptar/rechazar) -- el trigger de identidad de abajo es lo que
-- de verdad impide reescribir post_id/user_id.
create policy post_collaborators_update on post_collaborators
    for update
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

create or replace function private.protect_post_collaborator_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if current_user <> 'postgres' then
        new.post_id := old.post_id;
        new.user_id := old.user_id;
        new.invited_at := old.invited_at;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_post_collaborator_identity() from public, anon, authenticated;

drop trigger if exists trg_protect_post_collaborator_identity on post_collaborators;
create trigger trg_protect_post_collaborator_identity
    before update on post_collaborators
    for each row
    execute function private.protect_post_collaborator_identity();

-- Aviso real de invitación a colaborar, mismo patrón exacto que
-- notify_new_group_message (0064)/notify_new_compat_request.
alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response', 'repost', 'story_share', 'screenshot', 'live_start', 'post_collab_invite'));

create or replace function private.notify_post_collab_invite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_author_id uuid;
begin
    select author_id into v_author_id from public.posts where id = new.post_id;
    insert into public.notifications (recipient_id, actor_id, kind, payload)
    values (new.user_id, v_author_id, 'post_collab_invite', jsonb_build_object('post_id', new.post_id, 'actor_id', v_author_id));
    return new;
end;
$$;

revoke execute on function private.notify_post_collab_invite() from public, anon, authenticated;

drop trigger if exists trg_notify_post_collab_invite on post_collaborators;
create trigger trg_notify_post_collab_invite
    after insert on post_collaborators
    for each row
    execute function private.notify_post_collab_invite();
