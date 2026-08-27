-- ============================================================================
-- SOCIAL — Editar un comentario ya publicado, comparado con
-- Instagram/Facebook/Twitter/TikTok
-- Ver LOOP_STATE.md: la ronda de 0084_pin_comments.sql documentó
-- explícitamente que ni `comments` ni `reel_comments` tenían NINGUNA
-- política UPDATE de verdad utilizable por el propio autor -- la única
-- que se añadió entonces (`comments_update_pin`/`reel_comments_update_pin`)
-- es exclusiva del autor de la publicación/reel, para fijar/desfijar,
-- nunca para el autor del propio comentario.
--
-- Añade una segunda política UPDATE real (`comments_update_own`), esta
-- vez para el autor del comentario -- mismo criterio de "dos actores
-- distintos, dos políticas permisivas" ya usado en `messages`
-- (remitente/destinatario) y documentado explícitamente en 0084 como el
-- primer caso de esta sesión de alguien DISTINTO del autor de la fila
-- tocándola vía RLS directa.
--
-- Con dos políticas UPDATE abiertas sobre la misma tabla, el trigger de
-- protección tiene que cubrir AMBOS actores en una sola función --
-- extiende protect_comment_pin_only/protect_reel_comment_pin_only (última
-- versión: 0084) en vez de crear una nueva, mismo criterio ya establecido
-- para protect_message_columns/protect_group_message_identity. `edited_at`
-- se marca real (no solo `body`), mismo criterio que
-- 0049_messages_edit.sql, para poder mostrar "(editado)" en la UI.
--
-- Bug real encontrado y corregido durante esta misma ronda (verificado
-- contra PGlite, ver debug_comment.mjs): la versión 0084 de ambas
-- funciones era `security definer`. Con el guardia `current_user <>
-- 'postgres'` (necesario para dejar pasar las actualizaciones reales de
-- `like_count` desde sync_comment_like_count/sync_reel_comment_like_count,
-- ambas también security definer), `security definer` hace que
-- `current_user` DENTRO del propio trigger sea el DUEÑO de la función
-- (el rol de las migraciones, 'postgres'), nunca el actor real que
-- disparó el UPDATE -- el guardia quedaba siempre en `false` y CUALQUIERA
-- (ni siquiera el autor de la publicación, ni el del comentario) podía
-- reescribir `is_pinned`/`body` sin que el trigger lo revirtiera nunca.
-- Corregido quitando `security definer` de ambas funciones, mismo
-- criterio ya usado (sin `security definer`) en protect_message_columns.
-- ============================================================================

alter table comments add column edited_at timestamptz;
alter table reel_comments add column edited_at timestamptz;

create policy comments_update_own on comments
    for update
    using (author_id = (select auth.uid()))
    with check (author_id = (select auth.uid()));

create or replace function private.protect_comment_pin_only()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
    new.post_id := old.post_id;
    new.author_id := old.author_id;
    new.created_at := old.created_at;
    new.parent_comment_id := old.parent_comment_id;

    if new.like_count is distinct from old.like_count and current_user <> 'postgres' then
        new.like_count := old.like_count;
    end if;

    -- Fijar (0084): exclusivo del autor de la publicación.
    if new.is_pinned is distinct from old.is_pinned
        and not exists (select 1 from public.posts where posts.id = old.post_id and posts.author_id = v_uid)
        and current_user <> 'postgres' then
        new.is_pinned := old.is_pinned;
    end if;

    -- Editar (0123): exclusivo del propio autor del comentario.
    if (new.body is distinct from old.body or new.edited_at is distinct from old.edited_at)
        and v_uid <> old.author_id and current_user <> 'postgres' then
        new.body := old.body;
        new.edited_at := old.edited_at;
    end if;

    return new;
end;
$$;

create policy reel_comments_update_own on reel_comments
    for update
    using (author_id = (select auth.uid()))
    with check (author_id = (select auth.uid()));

create or replace function private.protect_reel_comment_pin_only()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
    new.reel_id := old.reel_id;
    new.author_id := old.author_id;
    new.created_at := old.created_at;
    new.parent_comment_id := old.parent_comment_id;

    if new.like_count is distinct from old.like_count and current_user <> 'postgres' then
        new.like_count := old.like_count;
    end if;

    if new.is_pinned is distinct from old.is_pinned
        and not exists (select 1 from public.reels where reels.id = old.reel_id and reels.author_id = v_uid)
        and current_user <> 'postgres' then
        new.is_pinned := old.is_pinned;
    end if;

    if (new.body is distinct from old.body or new.edited_at is distinct from old.edited_at)
        and v_uid <> old.author_id and current_user <> 'postgres' then
        new.body := old.body;
        new.edited_at := old.edited_at;
    end if;

    return new;
end;
$$;
