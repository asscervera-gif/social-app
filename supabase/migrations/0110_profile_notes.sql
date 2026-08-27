-- ============================================================================
-- SOCIAL — "Nota" real sobre el propio perfil, comparado con Instagram/
-- Facebook Messenger
--
-- Las dos dejan escribir un texto corto (Instagram: 60 caracteres) que
-- aparece como una burbuja sobre tu avatar en la bandeja de chats de la
-- gente con la que ya hablas, y caduca solo a las 24h -- pensado para un
-- "¿qué estás haciendo/pensando ahora?" efímero, distinto del caption de
-- una publicación (permanente) o de una historia (requiere una foto).
-- Confirmado en el propio código: `profiles` no tenía ningún concepto de
-- estado efímero de texto -- lo único parecido es la bio, permanente y
-- sin ningún límite de tiempo real.
--
-- Sin tabla ni política nueva: dos columnas normales en `profiles`, ya
-- cubiertas por las políticas existentes -- `profiles_update_own` (0002)
-- ya restringe la escritura a la propia fila sin restricción de columna
-- (mismo criterio que 0094/0096, preferencia resuelta en el cliente), y
-- `profiles_select_own`/`profiles_select_public` (0002) ya exponen
-- cualquier columna normal de otro perfil a quien pueda verlo -- aquí,
-- deliberadamente, sin exigir "seguir" a la persona (a diferencia de
-- Instagram real, que exige mutuo): SOCIAL solo muestra la nota en la
-- bandeja de chats ya existentes, una relación ya más estrecha que
-- "seguir" en este producto -- alcance intencional, no un descuido.
--
-- Aviso de honestidad: la caducidad de 24h es una responsabilidad real
-- del CLIENTE (comparar `note_updated_at` contra `now()` antes de
-- pintarla), no del servidor -- ninguna migración de esta sesión borra
-- filas por tiempo (ni siquiera `stories`, que expira igual por
-- comparación en la propia política RLS, `expires_at > now()`); aquí no
-- se sigue ese mismo patrón porque la nota vive en `profiles`, una fila
-- que ya existe por otras razones y no puede "expirar" sin desaparecer
-- el perfil entero -- limitación real reconocida aquí explícitamente.
-- ============================================================================

alter table profiles add column note_text text;
alter table profiles add column note_updated_at timestamptz;
alter table profiles add constraint profiles_note_text_length check (note_text is null or char_length(note_text) <= 60);
