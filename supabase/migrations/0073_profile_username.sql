-- ============================================================================
-- SOCIAL — Nombre de usuario único real (@handle), comparado con
-- Instagram/Twitter/TikTok: en las tres apps, cada cuenta tiene un
-- identificador permanente y único (@handle), distinto del nombre para
-- mostrar (que sí puede repetirse y cambiar libremente). SOCIAL solo
-- tenía `display_name` -- texto libre, no único, sin ninguna forma real
-- de encontrar o referenciar a alguien de manera inequívoca cuando dos
-- personas comparten el mismo nombre. Es también la pieza base que hace
-- falta para @menciones reales en captions/comentarios (hueco real
-- distinto, documentado aparte -- @mencionar un "nombre para mostrar" con
-- espacios y sin garantía de unicidad no funcionaría igual).
--
-- `username` nullable a propósito (no se puede forzar un valor único real
-- para las filas ya existentes sin inventar uno) -- se anima a elegirlo
-- desde el perfil, no se exige en un primer momento. Formato real ya
-- estandarizado por esas apps: minúsculas, dígitos y guión bajo, 3-20
-- caracteres -- normalizado a minúsculas en el propio cliente antes de
-- guardar, para no necesitar la extensión citext.
--
-- Sin RLS nueva: `profiles_update_own` (0002_rls.sql) ya cubre cualquier
-- columna del propio perfil, `username` incluido -- el `unique` real de
-- Postgres es quien de verdad impide dos cuentas con el mismo handle,
-- devolviendo un error real que el cliente traduce a "nombre de usuario
-- ya en uso".
-- ============================================================================

alter table profiles add column username text unique;
alter table profiles add constraint profiles_username_format
    check (username is null or username ~ '^[a-z0-9_]{3,20}$');
