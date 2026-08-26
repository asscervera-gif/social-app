-- ============================================================================
-- SOCIAL — Palabras silenciadas en comentarios, comparado con
-- Instagram/Twitter
--
-- Las dos dejan definir una lista de palabras propia que oculta
-- automáticamente cualquier comentario que las contenga -- sin tener que
-- moderar uno a uno, y sin bloquear a nadie (el comentario SIGUE
-- existiendo de verdad para todos los demás, incluido quien lo escribió;
-- solo desaparece para el dueño de la publicación/reel que activó ese
-- filtro). Confirmado en el propio código: el único filtrado de
-- contenido que existía era el bloqueo binario (`blocks`, todo o nada) y
-- el panel de moderación de admin (0036) -- nada a nivel de usuario
-- individual para su PROPIO contenido.
--
-- Mismo criterio ya usado para `muted_push_kinds` (0052_notification_prefs.sql):
-- columna simple en `profiles`, sin tabla aparte ni trigger de
-- protección (preferencia propia sin implicaciones de seguridad, a
-- diferencia de is_admin/is_banned).
--
-- Diseño real: esto NO es una restricción de visibilidad universal como
-- is_social_only/archived_at/close_friends (todas esas ocultan lo mismo
-- para TODO el mundo salvo una lista de excepciones) -- aquí cada
-- comentario sigue viéndose con normalidad para cualquiera EXCEPTO para
-- el dueño de la publicación que activó su propio filtro. Se resuelve
-- añadiendo una condición extra (AND NOT) a las políticas de SELECT ya
-- existentes, en vez de una política nueva (una política adicional
-- solo ampliaría la visibilidad vía OR, nunca la restringiría).
-- ============================================================================

alter table profiles add column if not exists muted_keywords text[] not null default '{}';

-- Mismo patrón exacto que private.is_blocked/private.has_accepted_social
-- (security definer + search_path vacío + revoke de ejecución directa):
-- hace falta porque comments_select/reel_comments_select tienen que leer
-- la lista de palabras silenciadas de OTRO usuario (el dueño de la
-- publicación/reel), algo que las políticas normales de `profiles` no
-- dejan hacer directamente para columnas ajenas.
create or replace function private.contains_muted_keyword(p_text text, p_owner_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.profiles, unnest(profiles.muted_keywords) as keyword
    where profiles.id = p_owner_id
      and char_length(keyword) > 0
      and p_text ilike ('%' || keyword || '%')
  );
$$;

revoke execute on function private.contains_muted_keyword(text, uuid) from public, anon, authenticated;
grant execute on function private.contains_muted_keyword(text, uuid) to authenticated, service_role;

drop policy if exists comments_select on comments;
create policy comments_select on comments
    for select
    using (
        exists (
            select 1 from posts
            where posts.id = comments.post_id
              and (
                  posts.author_id = (select auth.uid())
                  or (
                      posts.archived_at is null
                      and (
                          posts.is_social_only = false
                          or private.has_accepted_social((select auth.uid()), posts.author_id)
                      )
                  )
              )
        )
        and not (
            exists (select 1 from posts where posts.id = comments.post_id and posts.author_id = (select auth.uid()))
            and private.contains_muted_keyword(comments.body, (select auth.uid()))
        )
    );

drop policy if exists reel_comments_select on reel_comments;
create policy reel_comments_select on reel_comments
    for select
    using (
        exists (
            select 1 from reels
            where reels.id = reel_comments.reel_id
              and (
                  reels.author_id = (select auth.uid())
                  or reels.is_social_only = false
                  or private.has_accepted_social((select auth.uid()), reels.author_id)
              )
        )
        and not (
            exists (select 1 from reels where reels.id = reel_comments.reel_id and reels.author_id = (select auth.uid()))
            and private.contains_muted_keyword(reel_comments.body, (select auth.uid()))
        )
    );
