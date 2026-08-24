-- ============================================================================
-- SOCIAL — Fase 11: tienda real de avatares 3D
--
-- Hallazgo real: el "avatar" de toda la sesión hasta ahora era un círculo
-- con gradiente (PlaceholderAvatarProvider) o, en el prototipo HTML, un
-- busto SVG plano — nunca un avatar 3D real. Esta migración construye la
-- base de datos de la tienda real: catálogo de piezas (cuerpo/ropa/pelo,
-- mitad gratis y mitad de pago, tal como se pidió), monedas del usuario, y
-- qué piezas posee y lleva puestas cada perfil.
--
-- Los modelos 3D en sí (glTF) son packs CC0 externos (ITHappy Creative
-- Characters, Quaternius Universal Base Characters) — esta tabla solo
-- guarda la ruta al archivo dentro de assets/models/, no el modelo.
-- ============================================================================

alter table profiles add column coins integer not null default 100 check (coins >= 0);

-- Mismo patrón que protect_is_verified/protect_ban_columns: el cliente
-- nunca puede autoconcederse monedas con un UPDATE directo — solo
-- purchase_avatar_item() (más abajo, tras verificar el precio real) o
-- service_role pueden cambiar esta columna.
create or replace function private.protect_coins()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    -- current_user = 'postgres' es la señal real de "esta escritura viene
    -- de una función security definer nuestra" (verificado empíricamente
    -- contra Supabase real, no solo el simulador) — ver 0039 para el
    -- detalle completo de por qué auth.role() = 'service_role' a secas no
    -- basta para una función RPC callable por el cliente.
    if new.coins <> old.coins and auth.role() <> 'service_role' and current_user <> 'postgres' then
        new.coins := old.coins;
    end if;
    return new;
end;
$$;

revoke execute on function private.protect_coins() from public, anon, authenticated;

drop trigger if exists trg_protect_coins on profiles;
create trigger trg_protect_coins
    before update on profiles
    for each row
    execute function private.protect_coins();

create table avatar_items (
    id uuid primary key default uuid_generate_v4(),
    category text not null check (category in ('cuerpo', 'peinado', 'camiseta', 'pantalon', 'zapatos', 'sombrero', 'gafas', 'accesorio')),
    name text not null,
    model_path text not null,
    is_free boolean not null default false,
    price_coins integer not null default 0 check (price_coins >= 0),
    created_at timestamptz not null default now()
);

alter table avatar_items enable row level security;

create policy avatar_items_select_all on avatar_items
    for select
    using (true);

-- Solo insertable/editable por service_role (catálogo gestionado desde
-- fuera del cliente, igual que `events`) — sin política de insert/update
-- para authenticated, así que RLS lo bloquea por defecto.

create table profile_owned_items (
    profile_id uuid not null references profiles(id) on delete cascade,
    item_id uuid not null references avatar_items(id) on delete cascade,
    acquired_at timestamptz not null default now(),
    primary key (profile_id, item_id)
);

alter table profile_owned_items enable row level security;

create policy profile_owned_items_select_own on profile_owned_items
    for select
    using (profile_id = (select auth.uid()));

-- Sin política de insert para authenticated a propósito: la única vía real
-- de conseguir una pieza de pago es purchase_avatar_item() (comprueba
-- precio y descuenta monedas de forma atómica) — un insert directo del
-- cliente se saltaría el cobro.

create table profile_avatar_selections (
    profile_id uuid not null references profiles(id) on delete cascade,
    category text not null,
    item_id uuid not null references avatar_items(id) on delete cascade,
    updated_at timestamptz not null default now(),
    primary key (profile_id, category)
);

alter table profile_avatar_selections enable row level security;

-- Selección visible para todos (hace falta para renderizar el avatar 3D de
-- otra persona en su perfil/marcador de proximidad), pero solo se puede
-- seleccionar una pieza gratis o ya poseída — nunca una de pago sin pagarla.
create policy profile_avatar_selections_select_all on profile_avatar_selections
    for select
    using (true);

create policy profile_avatar_selections_upsert_own on profile_avatar_selections
    for insert
    with check (
        profile_id = (select auth.uid())
        and exists (
            select 1 from avatar_items ai
            where ai.id = item_id
            and (ai.is_free or exists (
                select 1 from profile_owned_items po
                where po.profile_id = (select auth.uid()) and po.item_id = ai.id
            ))
        )
    );

create policy profile_avatar_selections_update_own on profile_avatar_selections
    for update
    using (profile_id = (select auth.uid()))
    with check (
        profile_id = (select auth.uid())
        and exists (
            select 1 from avatar_items ai
            where ai.id = item_id
            and (ai.is_free or exists (
                select 1 from profile_owned_items po
                where po.profile_id = (select auth.uid()) and po.item_id = ai.id
            ))
        )
    );

-- security definer con el mismo patrón de elevación explícita ya usado en
-- admin_ban_user() (0037): comprueba el precio real server-side, descuenta
-- las monedas de forma atómica y concede la pieza — nunca confía en un
-- precio que mande el cliente.
create or replace function purchase_avatar_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_price integer;
    v_is_free boolean;
    v_coins integer;
begin
    select price_coins, is_free into v_price, v_is_free from public.avatar_items where id = p_item_id;
    if v_price is null then
        raise exception 'purchase_avatar_item: item % no existe', p_item_id;
    end if;
    if v_is_free then
        raise exception 'purchase_avatar_item: esta pieza ya es gratis, no hace falta comprarla';
    end if;
    if exists (select 1 from public.profile_owned_items where profile_id = (select auth.uid()) and item_id = p_item_id) then
        raise exception 'purchase_avatar_item: ya tienes esta pieza';
    end if;

    select coins into v_coins from public.profiles where id = (select auth.uid());
    if v_coins < v_price then
        raise exception 'purchase_avatar_item: monedas insuficientes (tienes %, cuesta %)', v_coins, v_price;
    end if;

    -- Escribe como current_user = 'postgres' (security definer), la señal
    -- real que protect_coins comprueba — sin necesidad de set_config,
    -- que no tiene ningún efecto en Supabase real (ver 0039).
    update public.profiles set coins = coins - v_price where id = (select auth.uid());
    insert into public.profile_owned_items (profile_id, item_id) values ((select auth.uid()), p_item_id);
end;
$$;

revoke execute on function purchase_avatar_item(uuid) from public, anon;
grant execute on function purchase_avatar_item(uuid) to authenticated;
