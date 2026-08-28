-- ============================================================================
-- SOCIAL — Programar la publicación de un post real, comparado con
-- Instagram/Twitter-X/TikTok (todas dejan elegir fecha/hora de
-- publicación futura para un post ya redactado)
--
-- Confirmado que no existe ningún campo de programación temporal para
-- posts: grep de "scheduled_at|scheduled_for|schedule_post" sobre
-- supabase/migrations/*.sql no devuelve nada. `post_drafts`
-- (0128_post_drafts.sql) ya deja guardar un borrador, pero SIN fecha de
-- publicación automática -- el usuario tiene que volver a abrir la app y
-- pulsar "Publicar" en el momento exacto, cero ayuda real para
-- planificar contenido con antelación (el caso de uso real de creadores
-- que sí resuelven las 4 apps comparables).
--
-- Diseño real: SIN pg_cron -- mismo criterio ya documentado en
-- 0082_mute_until.sql/0140_birthday.sql (este proyecto evita
-- deliberadamente trabajos en segundo plano server-side, y pg_cron ni
-- siquiera está probado en el arnés local de PGlite). En vez de un job
-- que publique en el instante exacto, `publish_due_scheduled_posts()` es
-- una función que el propio cliente llama al abrir Home (mismo criterio
-- que "catch up" ya usado para otras cosas en este proyecto) -- publica
-- los posts VENCIDOS del usuario que la llama, nunca los de otra
-- persona. Aviso de honestidad explícito: esto publica "la próxima vez
-- que ese usuario abra la app", no en el segundo exacto programado --
-- documentado así en vez de fingir un cron real que no existe.
-- ============================================================================

create table scheduled_posts (
    id uuid primary key default uuid_generate_v4(),
    author_id uuid not null references profiles(id) on delete cascade,
    media_url text,
    caption text,
    is_social_only boolean not null default false,
    scheduled_for timestamptz not null,
    created_at timestamptz not null default now()
);

alter table scheduled_posts enable row level security;

create index idx_scheduled_posts_author_id on scheduled_posts(author_id);

-- Solo el propio autor ve/gestiona sus posts programados -- a diferencia
-- de `posts_select` (0002_rls.sql), aquí no hay caso real de que otra
-- persona necesite ver un borrador programado todavía sin publicar.
create policy scheduled_posts_own on scheduled_posts
    for all
    using (author_id = (select auth.uid()))
    with check (author_id = (select auth.uid()));

-- security definer porque inserta en `posts` en nombre del autor real --
-- mismo criterio ya usado en otras funciones de este proyecto que cruzan
-- de una tabla a otra (ej. notify_*). `search_path = ''` + nombres
-- calificados con `public.` en todo el cuerpo, mismo patrón siempre.
create or replace function public.publish_due_scheduled_posts()
returns setof public.posts
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid uuid := (select auth.uid());
begin
    return query
    with due as (
        delete from public.scheduled_posts
        where author_id = v_uid
          and scheduled_for <= now()
        returning author_id, media_url, caption, is_social_only
    ), inserted as (
        insert into public.posts (author_id, media_url, caption, is_social_only)
        select author_id, media_url, caption, is_social_only from due
        returning *
    )
    select * from inserted;
end;
$$;

revoke all on function public.publish_due_scheduled_posts() from public;
grant execute on function public.publish_due_scheduled_posts() to authenticated;
