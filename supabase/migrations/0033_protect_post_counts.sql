-- ============================================================================
-- SOCIAL — Fase 9 (continuación): hallazgo de seguridad real — like_count/
-- comment_count escribibles directamente por el autor del post
--
-- Misma familia que 0029/0030/0032: `posts_write_own` (0002_rls.sql) es
-- `for all` (cubre UPDATE) y solo comprueba `author_id = auth.uid()` —
-- `like_count`/`comment_count` ya se mantienen correctamente vía trigger
-- desde `likes`/`comments` (`sync_post_like_count`/`sync_post_comment_count`,
-- 0007/0008), pero nada impedía que el AUTOR de un post escribiera
-- directamente `UPDATE posts SET like_count = 999999 WHERE id = mío` para
-- falsear sus propias métricas — la fuente de verdad son las filas reales
-- de `likes`/`comments`, no algo que el post-autor deba poder tocar.
-- Mismo patrón `pg_trigger_depth()` que 0032 (el escritor de confianza es
-- un trigger de este propio archivo, no una llamada `service_role`).
-- ============================================================================

create or replace function private.protect_post_counts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if pg_trigger_depth() <= 1 then
        new.like_count := old.like_count;
        new.comment_count := old.comment_count;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_post_counts() from public, anon, authenticated;

drop trigger if exists trg_protect_post_counts on posts;
create trigger trg_protect_post_counts
    before update on posts
    for each row
    execute function private.protect_post_counts();
