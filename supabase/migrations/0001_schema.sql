-- ============================================================================
-- SOCIAL — Fase 2: esquema Postgres
-- Tablas: profiles, profile_sections, posts, stories, follows, socials, chats,
-- messages, compatibility_votes, duels, compat_requests, notifications, activities
-- ============================================================================

create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------------------------
-- profiles: un registro por usuario, vinculado a auth.users
-- ---------------------------------------------------------------------------
create table profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    display_name text not null,
    avatar_url text,
    avatar_config jsonb,                    -- parámetros del motor de avatar (Fase 3)
    interests text[] not null default '{}',
    bio text,
    is_invisible boolean not null default false,
    location_public boolean not null default false,
    compat_public boolean not null default false,
    is_verified boolean not null default false,
    last_lat double precision,
    last_lng double precision,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- profile_sections: las 15 secciones del perfil completo, cada una con
-- su propia marca de público/privado (se desbloquean tras el onboarding).
-- ---------------------------------------------------------------------------
create table profile_sections (
    id uuid primary key default uuid_generate_v4(),
    profile_id uuid not null references profiles(id) on delete cascade,
    section_key text not null,               -- p.ej. 'work', 'studies', 'music', 'travel'...
    content jsonb not null default '{}',
    is_public boolean not null default false,
    updated_at timestamptz not null default now(),
    unique (profile_id, section_key)
);

-- ---------------------------------------------------------------------------
-- posts
-- ---------------------------------------------------------------------------
create table posts (
    id uuid primary key default uuid_generate_v4(),
    author_id uuid not null references profiles(id) on delete cascade,
    media_url text,
    caption text,
    is_social_only boolean not null default false,  -- solo visible con social aceptado
    like_count integer not null default 0,
    comment_count integer not null default 0,
    created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- stories (24h, como Fase 4 - Home)
-- ---------------------------------------------------------------------------
create table stories (
    id uuid primary key default uuid_generate_v4(),
    author_id uuid not null references profiles(id) on delete cascade,
    media_url text not null,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '24 hours')
);

-- ---------------------------------------------------------------------------
-- follows
-- ---------------------------------------------------------------------------
create table follows (
    follower_id uuid not null references profiles(id) on delete cascade,
    followee_id uuid not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (follower_id, followee_id),
    check (follower_id <> followee_id)
);

-- ---------------------------------------------------------------------------
-- socials: vínculo que requiere aceptación mutua (los dos síes)
-- ---------------------------------------------------------------------------
create table socials (
    id uuid primary key default uuid_generate_v4(),
    requester_id uuid not null references profiles(id) on delete cascade,
    addressee_id uuid not null references profiles(id) on delete cascade,
    status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
    created_at timestamptz not null default now(),
    responded_at timestamptz,
    unique (requester_id, addressee_id),
    check (requester_id <> addressee_id)
);

-- ---------------------------------------------------------------------------
-- chats: uno por par de usuarios (se abre tras social aceptado, o antes si
-- el perfil es público según regla de producto)
-- ---------------------------------------------------------------------------
create table chats (
    id uuid primary key default uuid_generate_v4(),
    user_a_id uuid not null references profiles(id) on delete cascade,
    user_b_id uuid not null references profiles(id) on delete cascade,
    compatibility_score integer not null default 50 check (compatibility_score between 0 and 100),
    created_at timestamptz not null default now(),
    unique (user_a_id, user_b_id),
    check (user_a_id <> user_b_id)
);

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
create table messages (
    id uuid primary key default uuid_generate_v4(),
    chat_id uuid not null references chats(id) on delete cascade,
    sender_id uuid not null references profiles(id) on delete cascade,
    body text,
    created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- compatibility_votes: cada pulsación +1/+10/+100 / -1/-10/-100 en el chat
-- ---------------------------------------------------------------------------
create table compatibility_votes (
    id uuid primary key default uuid_generate_v4(),
    chat_id uuid not null references chats(id) on delete cascade,
    voter_id uuid not null references profiles(id) on delete cascade,
    delta integer not null check (delta in (1, 10, 100, -1, -10, -100)),
    created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- duels: duelo de preguntas generado por IA (Fase 6)
-- ---------------------------------------------------------------------------
create table duels (
    id uuid primary key default uuid_generate_v4(),
    chat_id uuid not null references chats(id) on delete cascade,
    initiator_id uuid not null references profiles(id) on delete cascade,
    opponent_id uuid not null references profiles(id) on delete cascade,
    questions jsonb not null,               -- 5 preguntas de opción múltiple generadas por IA
    answers jsonb,
    compatibility_delta integer,
    explanation text,
    is_public boolean not null default false,
    created_at timestamptz not null default now(),
    completed_at timestamptz
);

-- ---------------------------------------------------------------------------
-- compat_requests: solicitud de ver el % de compatibilidad cuando no es público
-- ---------------------------------------------------------------------------
create table compat_requests (
    id uuid primary key default uuid_generate_v4(),
    requester_id uuid not null references profiles(id) on delete cascade,
    target_id uuid not null references profiles(id) on delete cascade,
    status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
    created_at timestamptz not null default now(),
    unique (requester_id, target_id)
);

-- ---------------------------------------------------------------------------
-- notifications
-- ---------------------------------------------------------------------------
create table notifications (
    id uuid primary key default uuid_generate_v4(),
    recipient_id uuid not null references profiles(id) on delete cascade,
    actor_id uuid references profiles(id) on delete set null,
    kind text not null check (kind in ('social', 'follow', 'fight', 'like', 'compat_request')),
    payload jsonb not null default '{}',
    read_at timestamptz,
    created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- activities: actividad sugerida cuando la compatibilidad supera el 50%
-- ---------------------------------------------------------------------------
create table activities (
    id uuid primary key default uuid_generate_v4(),
    chat_id uuid not null references chats(id) on delete cascade,
    suggestion text not null,
    created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Índices de acceso frecuente
-- ---------------------------------------------------------------------------
create index idx_posts_author on posts(author_id);
create index idx_messages_chat on messages(chat_id, created_at);
create index idx_notifications_recipient on notifications(recipient_id, created_at desc);
create index idx_socials_addressee on socials(addressee_id, status);
create index idx_profile_sections_profile on profile_sections(profile_id);
