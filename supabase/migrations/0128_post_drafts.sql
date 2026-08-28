-- Borrador de publicación no enviada, comparado con Instagram/Twitter/X --
-- las dos guardan automáticamente lo que ibas escribiendo si cierras el
-- compositor sin publicar, permitiendo retomarlo después. Confirmado en el
-- propio código: NewPostSheet.kt/NewPostView.swift guardan `caption` solo en
-- estado de Compose/SwiftUI (memoria) -- cerrar el sheet o salir de la app a
-- medias de escribir un post lo perdía todo sin aviso, sin ninguna tabla
-- `post_drafts` ni equivalente en todo el repo (confirmado con grep).
--
-- Alcance deliberado: un borrador por usuario (author_id como PRIMARY KEY,
-- upsert), solo texto (caption/location_name/is_sensitive) -- las fotos
-- elegidas (Uri/PHPickerResult locales) no se persisten aquí porque no
-- sobreviven de forma fiable a un reinicio real de la app en ninguna
-- plataforma, mismo criterio de honestidad ya aplicado varias veces esta
-- sesión (no simular una capacidad que no está verificada).
create table public.post_drafts (
  author_id uuid primary key references public.profiles(id) on delete cascade,
  caption text not null default '',
  location_name text,
  is_sensitive boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.post_drafts enable row level security;

create policy post_drafts_select_own on public.post_drafts
  for select using (author_id = auth.uid());

create policy post_drafts_insert_own on public.post_drafts
  for insert with check (author_id = auth.uid());

create policy post_drafts_update_own on public.post_drafts
  for update using (author_id = auth.uid()) with check (author_id = auth.uid());

create policy post_drafts_delete_own on public.post_drafts
  for delete using (author_id = auth.uid());
