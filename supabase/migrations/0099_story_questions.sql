-- ============================================================================
-- SOCIAL — Adhesivo de pregunta en una historia ("Pregúntame algo"),
-- comparado con Instagram
--
-- Hallazgo real: Instagram deja añadir una caja de pregunta a una
-- historia real -- cualquiera que la vea puede responder en privado (solo
-- quien publicó la historia ve las respuestas, con quién las escribió).
-- Confirmado en el propio código: `grep` de "story_question" en todo el
-- repo no encontró nada -- lo único real que existía sobre una historia
-- ajena era "responder" (0071_message_story_reply.sql), que manda un
-- mensaje de chat NORMAL citándola, visible como cualquier mensaje --
-- nada equivalente a una respuesta estructurada y privada a una pregunta
-- concreta.
--
-- Diseño real: dos tablas, `story_questions` (la caja en sí, una por
-- historia como mucho en el cliente, aunque el esquema no lo impone) y
-- `story_question_responses` (cada respuesta real, con quién la
-- escribió). Visibilidad de la pregunta en sí = misma regla real que
-- `stories_select` (0075_close_friends_stories.sql): quien puede ver la
-- historia puede ver que tiene una pregunta. Visibilidad de las
-- RESPUESTAS = privada, mismo criterio real que restricts_select_own
-- (0093)/starred_messages (0087): solo quien publicó la historia (y la
-- propia persona que respondió, sobre su propia respuesta) puede leerlas
-- -- ni siquiera otros espectadores de la misma historia ven las
-- respuestas ajenas.
-- ============================================================================

create table story_questions (
    id uuid primary key default uuid_generate_v4(),
    story_id uuid not null references stories(id) on delete cascade,
    prompt text not null check (char_length(prompt) between 1 and 200),
    created_at timestamptz not null default now()
);

alter table story_questions enable row level security;

create policy story_questions_select on story_questions
    for select
    using (
        exists (
            select 1 from stories
            where stories.id = story_questions.story_id
              and stories.expires_at > now()
              and (
                  stories.visibility = 'everyone'
                  or stories.author_id = (select auth.uid())
                  or private.is_close_friend(stories.author_id, (select auth.uid()))
              )
        )
    );

create policy story_questions_insert_own on story_questions
    for insert
    with check (
        exists (
            select 1 from stories
            where stories.id = story_questions.story_id
              and stories.author_id = (select auth.uid())
        )
    );

create policy story_questions_delete_own on story_questions
    for delete
    using (
        exists (
            select 1 from stories
            where stories.id = story_questions.story_id
              and stories.author_id = (select auth.uid())
        )
    );

create table story_question_responses (
    id uuid primary key default uuid_generate_v4(),
    question_id uuid not null references story_questions(id) on delete cascade,
    responder_id uuid not null references profiles(id) on delete cascade,
    body text not null check (char_length(body) between 1 and 500),
    created_at timestamptz not null default now()
);

alter table story_question_responses enable row level security;

-- Privada: ni siquiera otro espectador real de la misma historia ve la
-- respuesta de otra persona -- solo el propio autor de la historia y
-- quien escribió esa respuesta en concreto (sobre la suya).
create policy story_question_responses_select on story_question_responses
    for select
    using (
        responder_id = (select auth.uid())
        or exists (
            select 1 from story_questions
            join stories on stories.id = story_questions.story_id
            where story_questions.id = story_question_responses.question_id
              and stories.author_id = (select auth.uid())
        )
    );

create policy story_question_responses_insert_own on story_question_responses
    for insert
    with check (
        responder_id = (select auth.uid())
        and exists (
            select 1 from story_questions
            join stories on stories.id = story_questions.story_id
            where story_questions.id = story_question_responses.question_id
              and stories.expires_at > now()
              and (
                  stories.visibility = 'everyone'
                  or stories.author_id = (select auth.uid())
                  or private.is_close_friend(stories.author_id, (select auth.uid()))
              )
              and not private.is_blocked(story_question_responses.responder_id, stories.author_id)
        )
    );

create policy story_question_responses_delete_own on story_question_responses
    for delete
    using (responder_id = (select auth.uid()));

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response'));

-- Avisa al autor real de la historia en cuanto llega una respuesta real
-- -- mismo criterio real que Instagram (sin esto, nunca sabría que debe
-- entrar a mirar). `security definer` porque el trigger necesita leer
-- `stories.author_id` de una fila que la política normal de `stories`
-- ya deja ver a quien responde (no hace falta elevar privilegios para
-- ESO en concreto), pero sí necesita insertar en `notifications` a
-- nombre de otra persona (el destinatario real, no quien responde) --
-- mismo patrón exacto que el resto de triggers de aviso de esta sesión.
create or replace function private.notify_story_question_response()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
begin
  select stories.author_id into v_author_id
  from public.story_questions
  join public.stories on stories.id = story_questions.story_id
  where story_questions.id = new.question_id;

  insert into public.notifications (recipient_id, actor_id, kind, payload)
  values (
    v_author_id,
    new.responder_id,
    'story_question_response',
    jsonb_build_object('actor_id', new.responder_id, 'question_id', new.question_id, 'response_id', new.id)
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_story_question_response on story_question_responses;
create trigger trg_notify_story_question_response
  after insert on story_question_responses
  for each row execute function private.notify_story_question_response();
