-- ============================================================================
-- SOCIAL — Fase 7: bloqueo y denuncia
-- ============================================================================

create table blocks (
    blocker_id uuid not null references profiles(id) on delete cascade,
    blocked_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id),
    check (blocker_id <> blocked_id)
);

create table reports (
    id uuid primary key default uuid_generate_v4(),
    reporter_id uuid not null references profiles(id) on delete cascade,
    reported_id uuid not null references profiles(id) on delete cascade,
    reason text not null,
    details text,
    status text not null default 'open' check (status in ('open', 'reviewed', 'dismissed')),
    created_at timestamptz not null default now()
);

alter table blocks enable row level security;
alter table reports enable row level security;

create index idx_blocks_blocker on blocks(blocker_id);
create index idx_reports_reported on reports(reported_id);

create policy blocks_select_own on blocks
    for select
    using (blocker_id = (select auth.uid()));

create policy blocks_insert_own on blocks
    for insert
    with check (blocker_id = (select auth.uid()));

create policy blocks_delete_own on blocks
    for delete
    using (blocker_id = (select auth.uid()));

-- El denunciante puede crear e insertar reports, pero no leer denuncias
-- ajenas ni las suyas (las revisa moderación con service_role, no el cliente).
create policy reports_insert_own on reports
    for insert
    with check (reporter_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Modo Evento: recintos donde todos los asistentes se ven entre sí.
-- ---------------------------------------------------------------------------
create table events (
    id uuid primary key default uuid_generate_v4(),
    name text not null,
    starts_at timestamptz not null,
    ends_at timestamptz not null,
    venue_lat double precision not null,
    venue_lng double precision not null,
    radius_meters integer not null default 150
);

create table event_attendees (
    event_id uuid not null references events(id) on delete cascade,
    profile_id uuid not null references profiles(id) on delete cascade,
    social_count integer not null default 0,   -- para el ranking del evento
    joined_at timestamptz not null default now(),
    primary key (event_id, profile_id)
);

alter table events enable row level security;
alter table event_attendees enable row level security;

create index idx_event_attendees_event on event_attendees(event_id, social_count desc);

create policy events_select_all on events
    for select
    using (true);

create policy event_attendees_select_all on event_attendees
    for select
    using (true);

create policy event_attendees_insert_own on event_attendees
    for insert
    with check (profile_id = (select auth.uid()));
