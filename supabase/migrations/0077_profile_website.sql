-- ============================================================================
-- SOCIAL — Enlace externo en el perfil ("link in bio"), comparado con
-- Instagram/TikTok/Twitter
--
-- Las tres apps dejan poner una URL bajo la bio, tocable, que abre el
-- navegador -- uno de los pocos sitios donde esas apps permiten un enlace
-- saliente real. Confirmado en el propio código: `EditProfileSheet.kt`/
-- `EditProfileView.swift` solo tenían nombre, bio, username
-- (0073_profile_username.sql) y el look del avatar -- ningún campo de URL
-- en absoluto, ni en el esquema (`profiles`, 0001_schema.sql) ni en la
-- cabecera del perfil (`PerfilScreen.kt`/`ProfileViewerScreen.kt`).
--
-- Sin comprobación de formato estricta a nivel de base de datos (mismo
-- criterio ya aplicado a `username`: normalización simple, no una
-- infraestructura nueva) -- el cliente antepone "https://" si falta el
-- esquema antes de guardar, y solo un límite de longitud real aquí. Sin
-- RLS nueva: `profiles_update_own` (0002_rls.sql) ya cubre la
-- actualización de cualquier columna propia.
-- ============================================================================

alter table profiles add column website_url text;
alter table profiles add constraint profiles_website_url_length
    check (website_url is null or char_length(website_url) <= 200);
