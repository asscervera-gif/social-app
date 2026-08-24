-- ============================================================================
-- SOCIAL — Fase 8: sesión real de duelo (cierra el hallazgo de integridad
-- de duel-ai documentado en LOOP_STATE.md)
--
-- Hallazgo más profundo de lo que se había mitigado antes: `correctIndex`
-- viajaba directamente en la respuesta de `generate_questions` al cliente
-- (es parte del propio `DuelQuestion` que se usa para pintar las opciones),
-- así que cualquiera podía ver las respuestas correctas antes de elegir —
-- la mitigación anterior (acotar questionCount/correctCount a un rango
-- razonable en score_duel) solo cerraba el caso más burdo, no este.
--
-- Esta tabla guarda las preguntas COMPLETAS (con correctIndex) solo en el
-- servidor; el cliente solo recibe prompt+options. score_duel valida las
-- respuestas contra esta sesión real, no contra un correctCount que manda
-- el propio cliente.
-- ============================================================================

create table duel_sessions (
    id uuid primary key default uuid_generate_v4(),
    initiator_id uuid not null references profiles(id) on delete cascade,
    questions jsonb not null,  -- incluye correctIndex; solo lo lee la Edge Function (service_role)
    used boolean not null default false,
    created_at timestamptz not null default now()
);

create index if not exists idx_duel_sessions_initiator on duel_sessions(initiator_id, created_at desc);

alter table duel_sessions enable row level security;

-- Ninguna política de select/insert/update para authenticated: esta tabla
-- solo la toca la Edge Function con service_role (que bypasea RLS), igual
-- que `ai_usage` en 0004_ai_usage.sql. El cliente nunca debe poder leer
-- `questions` (contendría las respuestas correctas).
