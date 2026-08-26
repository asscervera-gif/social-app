-- ============================================================================
-- SOCIAL — Fijar un comentario, comparado con Instagram ("Pin comment") y
-- Twitter/X ("Pinned reply")
--
-- Las dos dejan al autor de la publicación fijar UN comentario (propio o
-- ajeno) para que aparezca siempre arriba de la lista, sin tener que
-- moderar ni borrar nada. Confirmado en el propio código: `comments`
-- (0008_comments.sql) y `reel_comments` (0050_reels.sql) solo tienen
-- políticas `select`/`insert_own`/`delete_own` -- ni siquiera existe una
-- política UPDATE, así que ni el propio autor del comentario puede
-- editarlo, y mucho menos el autor de la publicación fijarlo.
--
-- Diseño real, primer caso de esta sesión donde alguien DISTINTO del
-- autor de la fila puede tocarla vía RLS directa (sin pasar por una
-- función security definer ni necesitar rol admin): el autor de la
-- publicación (`posts.author_id`/`reels.author_id`), no el autor del
-- comentario, es quien tiene permiso real para fijar/desfijar. Como esa
-- misma política de UPDATE queda abierta, un trigger aparte congela todas
-- las demás columnas (mismo espíritu que protect_call_identity/
-- protect_group_message_identity) para que esta vía nunca sirva para
-- reescribir el body o adjudicarse el comentario -- solo is_pinned puede
-- cambiar por aquí.
-- ============================================================================

alter table comments add column is_pinned boolean not null default false;
alter table reel_comments add column is_pinned boolean not null default false;

create policy comments_update_pin on comments
    for update
    using (
        exists (select 1 from posts where posts.id = comments.post_id and posts.author_id = (select auth.uid()))
    )
    with check (
        exists (select 1 from posts where posts.id = comments.post_id and posts.author_id = (select auth.uid()))
    );

create or replace function private.protect_comment_pin_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    new.post_id := old.post_id;
    new.author_id := old.author_id;
    new.body := old.body;
    new.created_at := old.created_at;
    return new;
end;
$$;

drop trigger if exists trg_protect_comment_pin_only on comments;
create trigger trg_protect_comment_pin_only
    before update on comments
    for each row execute function private.protect_comment_pin_only();

create policy reel_comments_update_pin on reel_comments
    for update
    using (
        exists (select 1 from reels where reels.id = reel_comments.reel_id and reels.author_id = (select auth.uid()))
    )
    with check (
        exists (select 1 from reels where reels.id = reel_comments.reel_id and reels.author_id = (select auth.uid()))
    );

create or replace function private.protect_reel_comment_pin_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    new.reel_id := old.reel_id;
    new.author_id := old.author_id;
    new.body := old.body;
    new.created_at := old.created_at;
    return new;
end;
$$;

drop trigger if exists trg_protect_reel_comment_pin_only on reel_comments;
create trigger trg_protect_reel_comment_pin_only
    before update on reel_comments
    for each row execute function private.protect_reel_comment_pin_only();
