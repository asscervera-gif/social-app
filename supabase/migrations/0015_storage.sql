-- ============================================================================
-- SOCIAL — Fase 9: Supabase Storage real, segundo hueco raíz más grave
--
-- Hallazgo: no había ninguna integración de Storage en ningún sitio del
-- proyecto — Historias, chat multimedia, avatar 3D y fotos en publicaciones
-- llevaban toda la sesión documentados como "bloqueados por falta de
-- Storage", asumiendo que no había red disponible para verificarlo. Se
-- confirmó que sí hay acceso a internet real en este entorno (Gradle
-- resolvió `storage-kt:2.5.4` en caliente), así que este bloqueo deja de
-- ser cierto y se cierra de verdad.
--
-- Bucket público único "media", con convención de carpeta por usuario
-- (`{user_id}/archivo.ext`) — mismo patrón documentado oficialmente por
-- Supabase para Storage RLS: `storage.foldername(name)` devuelve las
-- partes de la ruta como array, `[1]` es el primer segmento.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

-- Lectura pública (las fotos de posts/avatares son públicas por diseño de
-- producto, igual que avatar_url/media_url ya eran columnas de lectura
-- pública vía las políticas de `posts`/`profiles`).
create policy media_select_public on storage.objects
    for select
    using (bucket_id = 'media');

-- Solo se puede subir dentro de la propia carpeta ({auth.uid()}/...) —
-- impide que un usuario suba archivos haciéndose pasar por otro.
create policy media_insert_own on storage.objects
    for insert
    with check (
        bucket_id = 'media'
        and (storage.foldername(name))[1] = (select auth.uid()::text)
    );

create policy media_update_own on storage.objects
    for update
    using (
        bucket_id = 'media'
        and (storage.foldername(name))[1] = (select auth.uid()::text)
    );

create policy media_delete_own on storage.objects
    for delete
    using (
        bucket_id = 'media'
        and (storage.foldername(name))[1] = (select auth.uid()::text)
    );
