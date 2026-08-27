-- ============================================================================
-- SOCIAL — Restringir una cuenta real, comparado con Instagram
--
-- Hallazgo real: el único filtrado de contenido a nivel de usuario que
-- existía era binario -- bloquear (`blocks`, corta todo por completo y
-- avisa indirectamente, ya que la persona bloqueada deja de poder
-- interactuar) o silenciar palabras concretas (`muted_keywords`, 0078,
-- oculta un comentario SOLO al dueño de la publicación). Instagram real
-- tiene una tercera vía, deliberadamente MÁS SUAVE que bloquear:
-- "Restringir" -- los comentarios de esa persona en tus publicaciones
-- dejan de verse para TODOS LOS DEMÁS (excepto para quien los escribió,
-- que los sigue viendo con total normalidad, sin enterarse de nada) y tú
-- decides en privado si aprobarlos o no. A diferencia de bloquear, la
-- persona restringida NUNCA recibe ningún aviso ni indicio real -- ese es
-- precisamente el punto real de esta herramienta frente a bloquear
-- (pensada para gestionar acoso sin una confrontación directa ni
-- notificación que pueda escalar la situación).
--
-- Mismo criterio de diseño ya documentado en 0078_muted_keywords.sql:
-- esto NO es una restricción de visibilidad universal -- se resuelve
-- añadiendo una condición extra (AND NOT) a comments_select/
-- reel_comments_select ya existentes, en vez de una política nueva (que
-- solo ampliaría la visibilidad vía OR, nunca la restringiría). Aquí la
-- dirección es la opuesta a la de 0078: 0078 oculta el comentario SOLO
-- al dueño; restringir lo oculta a TODOS MENOS al dueño y a quien lo
-- escribió.
--
-- restricts_select_own (mismo criterio real que blocks_select_own,
-- 0003_safety.sql): SOLO quien restringe puede leer su propia lista --
-- la persona restringida jamás puede consultar si está en la lista de
-- alguien, ni siquiera indirectamente vía esta tabla. No se puede
-- restringir a alguien ya bloqueado (bloquear ya es un corte completo,
-- mismo criterio que follows_write_own con is_blocked, 0011).
--
-- Alcance deliberado de esta ronda: SOLO comentarios (posts/reels), la
-- parte más reconocible real de "Restringir". Instagram real también
-- mueve los mensajes directos de esa persona a una bandeja de
-- "solicitudes" aparte y oculta el estado de "en línea"/"escribiendo" --
-- ese lado de chat no se toca aquí (SOCIAL no tiene hoy ningún concepto
-- de "solicitud de mensaje" para chats 1:1 en absoluto -- construirlo de
-- verdad es un hueco real aparte, no una extensión de una tarde de esta
-- misma migración).
-- ============================================================================

create table restricts (
    restricter_id uuid not null references profiles(id) on delete cascade,
    restricted_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (restricter_id, restricted_id),
    check (restricter_id <> restricted_id)
);

alter table restricts enable row level security;

create policy restricts_select_own on restricts
    for select
    using (restricter_id = (select auth.uid()));

create policy restricts_insert_own on restricts
    for insert
    with check (
        restricter_id = (select auth.uid())
        and not private.is_blocked(restricter_id, restricted_id)
    );

create policy restricts_delete_own on restricts
    for delete
    using (restricter_id = (select auth.uid()));

-- Mismo patrón exacto que private.is_blocked/private.contains_muted_keyword
-- (security definer + search_path vacío + revoke de ejecución directa):
-- hace falta porque comments_select/reel_comments_select tienen que
-- comprobar una relación ajena (si el dueño de la publicación restringió
-- a quien escribió el comentario), algo que una política normal sobre
-- `restricts` no dejaría hacer directamente para nadie que no sea el
-- propio restricter_id.
create or replace function private.is_restricted(p_owner_id uuid, p_commenter_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1 from public.restricts
    where restricter_id = p_owner_id and restricted_id = p_commenter_id
  );
$$;

revoke execute on function private.is_restricted(uuid, uuid) from public, anon, authenticated;
grant execute on function private.is_restricted(uuid, uuid) to authenticated, service_role;

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
        and not (
            exists (
                select 1 from posts
                where posts.id = comments.post_id
                  and private.is_restricted(posts.author_id, comments.author_id)
                  and (select auth.uid()) <> posts.author_id
                  and (select auth.uid()) <> comments.author_id
            )
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
        and not (
            exists (
                select 1 from reels
                where reels.id = reel_comments.reel_id
                  and private.is_restricted(reels.author_id, reel_comments.author_id)
                  and (select auth.uid()) <> reels.author_id
                  and (select auth.uid()) <> reel_comments.author_id
            )
        )
    );
