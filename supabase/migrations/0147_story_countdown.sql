-- ============================================================================
-- SOCIAL — Sticker de cuenta atrás real en Historias, comparado con
-- Instagram (Countdown, desde 2019, con botón "Recordarme")/Snapchat
--
-- `stories` ya tiene texto/mención (0143), pregunta (0099), encuesta
-- (0100), compartir post (0129) y enlace/swipe-up (0146), pero ningún
-- sticker de cuenta atrás a una fecha real -- confirmado con grep de
-- "countdown|remind_me|reminder|target_date" sin resultados fuera del
-- countdown de duelos (DuelViewModel, sin relación con historias).
--
-- Diseño real: SIN pg_cron -- mismo criterio ya documentado en
-- 0082/0140/0141/0145 (este proyecto evita deliberadamente trabajos en
-- segundo plano server-side). `notify_due_story_countdowns()` sigue el
-- MISMO patrón exacto ya construido en 0141_scheduled_posts.sql
-- (publish_due_scheduled_posts): una función que el propio cliente llama
-- al abrir Home, que resuelve los recordatorios VENCIDOS del usuario que
-- la llama y genera un aviso real -- honestidad explícita: esto avisa
-- "la próxima vez que ese usuario abra la app", no en el segundo exacto
-- de la cuenta atrás. Un push server-side real en el instante exacto
-- necesitaría pg_cron (evitado a propósito) o una llamada del cliente a
-- send-push con la SERVICE_ROLE_KEY (imposible desde el cliente sin
-- filtrar esa clave) -- ninguna de las dos es segura ni honesta aquí.
-- ============================================================================

alter table stories add column countdown_label text check (countdown_label is null or char_length(countdown_label) <= 60);
alter table stories add column countdown_target_at timestamptz;

create table story_countdown_reminders (
    story_id uuid not null references stories(id) on delete cascade,
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (story_id, user_id)
);

alter table story_countdown_reminders enable row level security;

-- Cada quien gestiona solo su propio recordatorio -- mismo criterio que
-- hashtag_follows/recent_searches, sin necesitar que el autor de la
-- historia vea quién se apuntó todavía (alcance acotado a propósito).
create policy story_countdown_reminders_own on story_countdown_reminders
    for all
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post', 'story_question_response', 'repost', 'story_share', 'screenshot', 'live_start', 'post_collab_invite', 'countdown_due'));

-- Mismo patrón exacto que publish_due_scheduled_posts() (0141): resuelve
-- los recordatorios VENCIDOS del usuario que llama, nunca los de otra
-- persona -- borra la fila (evita re-avisar) e inserta un aviso real.
create or replace function public.notify_due_story_countdowns()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid uuid := (select auth.uid());
    v_reminder record;
begin
    for v_reminder in
        delete from public.story_countdown_reminders scr
        using public.stories s
        where scr.story_id = s.id
          and scr.user_id = v_uid
          and s.countdown_target_at is not null
          and s.countdown_target_at <= now()
        returning scr.story_id
    loop
        insert into public.notifications (recipient_id, actor_id, kind, payload)
        values (v_uid, v_uid, 'countdown_due', jsonb_build_object('story_id', v_reminder.story_id));
    end loop;
end;
$$;

revoke all on function public.notify_due_story_countdowns() from public;
grant execute on function public.notify_due_story_countdowns() to authenticated;
