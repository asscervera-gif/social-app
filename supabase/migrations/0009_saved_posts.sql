-- ============================================================================
-- SOCIAL — Fase 8: guardar publicaciones (bookmarks)
--
-- Hueco documentado: el icono de "guardar" en PostCard (Android/iOS) era
-- puramente decorativo (`Image(systemName: "bookmark")` sin Button/onClick
-- alguno) — mismo patrón que el "like" falso encontrado antes de esta
-- sesión, pero aquí ni siquiera había un intento de wiring. Se construye
-- aquí la pieza completa: tabla, RLS. Sin trigger de contador (no hay
-- columna `posts.save_count` en el esquema — a diferencia de like/comment,
-- guardar es privado del usuario, no un contador público del post, así que
-- no aplica el mismo patrón de sync).
-- ============================================================================

create table saved_posts (
    id uuid primary key default uuid_generate_v4(),
    post_id uuid not null references posts(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (post_id, user_id)
);

create index if not exists idx_saved_posts_user on saved_posts(user_id, created_at desc);

alter table saved_posts enable row level security;

-- A diferencia de likes/comments (públicos), guardado es privado: solo el
-- propio usuario puede ver, crear o borrar sus propios guardados.
create policy saved_posts_select_own on saved_posts
    for select
    using (user_id = (select auth.uid()));

create policy saved_posts_insert_own on saved_posts
    for insert
    with check (user_id = (select auth.uid()));

create policy saved_posts_delete_own on saved_posts
    for delete
    using (user_id = (select auth.uid()));
