-- ============================================================================
-- SOCIAL — Activar avisos de publicaciones de una cuenta ("🔔"), comparado
-- con Instagram/Twitter/X
--
-- Hallazgo real: las dos dejan tocar una campana en el perfil de alguien
-- que sigues para que te avise cada vez que publique algo nuevo -- a
-- diferencia del resto de interacciones (like/comentario/mensaje/mención),
-- una publicación nueva de alguien que sigues NUNCA generaba ningún aviso
-- real en SOCIAL, ni siquiera opcional. Confirmado en el propio código:
-- `grep` de "new_post"/"post_notification" en todo el repo no encontró
-- nada.
--
-- Diseño real, mismo patrón que restricts (0093)/close_friends (0075):
-- tabla de suscripción propia (`subscriber_id`, `creator_id`) con
-- `select`/`insert`/`delete` limitados al propio `subscriber_id` -- no
-- hay ninguna vía real por la que alguien deba saber quién activó avisos
-- sobre su cuenta (mismo criterio de privacidad que restricts_select_own).
-- Trigger `AFTER INSERT on posts` real que avisa a cada suscriptor --
-- mismo criterio de bloqueo ya aplicado en el resto de triggers de aviso
-- de esta sesión (mención, mensaje de grupo): si alguno de los dos
-- bloqueó al otro después de suscribirse, no se genera el aviso.
-- ============================================================================

create table post_notification_subscriptions (
    subscriber_id uuid not null references profiles(id) on delete cascade,
    creator_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (subscriber_id, creator_id),
    check (subscriber_id <> creator_id)
);

alter table post_notification_subscriptions enable row level security;

create policy post_notification_subscriptions_select_own on post_notification_subscriptions
    for select
    using (subscriber_id = (select auth.uid()));

create policy post_notification_subscriptions_insert_own on post_notification_subscriptions
    for insert
    with check (
        subscriber_id = (select auth.uid())
        and not private.is_blocked(subscriber_id, creator_id)
    );

create policy post_notification_subscriptions_delete_own on post_notification_subscriptions
    for delete
    using (subscriber_id = (select auth.uid()));

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check
  check (kind in ('social', 'follow', 'fight', 'like', 'compat_request', 'comment', 'social_accepted', 'compat_accepted', 'message', 'reel_like', 'reel_comment', 'comment_like', 'reel_comment_like', 'group_message', 'mention', 'new_post'));

create or replace function private.notify_post_subscribers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (recipient_id, actor_id, kind, payload)
  select
    post_notification_subscriptions.subscriber_id,
    new.author_id,
    'new_post',
    jsonb_build_object('actor_id', new.author_id, 'post_id', new.id)
  from public.post_notification_subscriptions
  where post_notification_subscriptions.creator_id = new.author_id
    and not private.is_blocked(post_notification_subscriptions.subscriber_id, new.author_id);
  return new;
end;
$$;

drop trigger if exists trg_notify_post_subscribers on posts;
create trigger trg_notify_post_subscribers
  after insert on posts
  for each row execute function private.notify_post_subscribers();
