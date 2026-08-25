-- ============================================================================
-- SOCIAL — "Pubs de socials": etiquetar una publicación con quién la
-- compartiste, comparado con SOCIAL_APP.html (sección "Pubs de socials"
-- del perfil: publicaciones con la etiqueta "con Marta"/"con Leo",
-- visibles solo entre socials).
--
-- Hallazgo real: no existía ninguna forma de decir "esta publicación es
-- CON tal persona" -- `is_social_only` (0001_schema.sql) ya controla
-- QUIÉN puede VER un post (público vs. solo socials aceptados), pero es
-- un concepto distinto y ortogonal a CON QUIÉN se hizo la publicación.
-- Columna nullable simple (no una tabla de muchos-a-muchos): el boceto
-- muestra como mucho UNA etiqueta por publicación ("con Marta"), no
-- varias personas etiquetadas a la vez.
--
-- Sin trigger que valide que `tagged_profile_id` sea un social aceptado
-- real: el cliente solo ofrece elegir de la lista de socials aceptados
-- (mismo dato que SocialsListViewModel ya usa), igual que "etiquetar
-- personas" en Instagram no exige ninguna relación previa a nivel de
-- base de datos -- no es un hueco de seguridad, es una decisión de
-- alcance deliberada.
-- ============================================================================

alter table posts add column if not exists tagged_profile_id uuid references profiles(id) on delete set null;

create index if not exists idx_posts_tagged_profile on posts(tagged_profile_id);
