-- ============================================================================
-- SOCIAL — rate limiting de la Edge Function duel-ai (security_checklist.md #3)
-- ============================================================================

create table ai_usage (
    id uuid primary key default uuid_generate_v4(),
    user_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now()
);

create index idx_ai_usage_user_time on ai_usage(user_id, created_at desc);

alter table ai_usage enable row level security;

-- Solo la Edge Function (service_role, que bypassa RLS) escribe aquí.
-- El usuario puede consultar su propio historial de uso si se lo permitimos,
-- pero no puede insertar ni modificarlo directamente.
create policy ai_usage_select_own on ai_usage
    for select
    using (user_id = (select auth.uid()));
