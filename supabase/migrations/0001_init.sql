-- Fiorente Chords — Fase 0: esquema inicial (equipos, membresías, canciones, setlist, invitaciones)
-- Correr una sola vez en el SQL Editor de un proyecto Supabase nuevo (Settings > Database > SQL Editor,
-- o vía `supabase db push` si usas el CLI).

create extension if not exists pgcrypto;

-- ============================================================
-- TABLAS
-- ============================================================

create table teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text unique,
  created_by  uuid not null references auth.users(id),
  plan        text not null default 'free' check (plan in ('free','paid')),
  song_limit  int not null default 30,
  created_at  timestamptz not null default now()
);

create table memberships (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null default 'member' check (role in ('admin','member')),
  created_at  timestamptz not null default now(),
  unique (team_id, user_id)
);

create table songs (
  id             uuid primary key default gen_random_uuid(),
  team_id        uuid not null references teams(id) on delete cascade,
  import_key     text, -- slug estable para que el import de Excel/Sheets actualice en vez de duplicar
  title          text not null,
  artist         text not null default '',
  key            text not null default 'C',
  original_key   text not null default '',
  bpm            int,
  youtube        text not null default '',
  mp3            text not null default '',
  sheet_music    text not null default '',
  sequence       text[] not null default '{}',
  annotations    text not null default '',
  chords         text not null default '',
  favorite       boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (team_id, import_key)
);
create index songs_team_id_idx on songs(team_id);

create table setlist_items (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  song_id     uuid not null references songs(id) on delete cascade,
  position    double precision not null,
  created_at  timestamptz not null default now(),
  unique (team_id, song_id)
);
create index setlist_items_team_id_idx on setlist_items(team_id);

create table invite_tokens (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  token       text not null unique default encode(gen_random_bytes(16), 'hex'),
  created_by  uuid not null references auth.users(id),
  expires_at  timestamptz not null default (now() + interval '7 days'),
  max_uses    int, -- null = sin límite de usos
  uses        int not null default 0,
  created_at  timestamptz not null default now()
);

-- updated_at automático en songs
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
create trigger songs_set_updated_at
  before update on songs
  for each row execute function set_updated_at();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

create or replace function is_team_member(check_team_id uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from memberships
    where team_id = check_team_id and user_id = auth.uid()
  );
$$;

create or replace function is_team_admin(check_team_id uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from memberships
    where team_id = check_team_id and user_id = auth.uid() and role = 'admin'
  );
$$;

alter table teams enable row level security;
alter table memberships enable row level security;
alter table songs enable row level security;
alter table setlist_items enable row level security;
alter table invite_tokens enable row level security;

-- teams: cualquier miembro puede leer su propio equipo; solo admin puede modificarlo.
-- La creación de equipos se hace vía la función create_team_with_owner (RPC), no INSERT directo.
create policy teams_select on teams for select
  using (is_team_member(id));
create policy teams_update on teams for update
  using (is_team_admin(id));

-- memberships: cualquier miembro del equipo puede ver quiénes son sus compañeros de equipo.
-- Solo un admin puede agregar/quitar miembros directamente (las altas normales pasan por redeem_invite).
create policy memberships_select on memberships for select
  using (is_team_member(team_id));
create policy memberships_insert_by_admin on memberships for insert
  with check (is_team_admin(team_id));
create policy memberships_delete_by_admin on memberships for delete
  using (is_team_admin(team_id));

-- songs: cualquier miembro del equipo puede leer/crear/editar/borrar canciones de su equipo.
-- No hay distinción admin/member aquí a propósito — cualquiera en el equipo puede editar el repertorio,
-- igual que hoy cualquiera con la llave de GitHub puede escribir.
create policy songs_all on songs for all
  using (is_team_member(team_id))
  with check (is_team_member(team_id));

-- setlist_items: mismo criterio que songs.
create policy setlist_items_all on setlist_items for all
  using (is_team_member(team_id))
  with check (is_team_member(team_id));

-- invite_tokens: nadie lee la tabla directamente (ni con SELECT). Los links de invitación se
-- generan y se canjean únicamente a través de las funciones RPC de abajo (security definer),
-- que no exponen tokens de otros equipos.
create policy invite_tokens_admin_manage on invite_tokens for all
  using (is_team_admin(team_id))
  with check (is_team_admin(team_id));

-- ============================================================
-- FUNCIONES RPC
-- ============================================================

-- Crea un equipo y la membresía de admin del creador en una sola transacción — evita el problema
-- de "necesitas ser miembro para pasar la política de INSERT en memberships, pero aún no lo eres".
create or replace function create_team_with_owner(team_name text)
returns uuid
language plpgsql
security definer
as $$
declare
  new_team_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para crear un equipo.';
  end if;
  insert into teams (name, created_by) values (team_name, auth.uid())
    returning id into new_team_id;
  insert into memberships (team_id, user_id, role) values (new_team_id, auth.uid(), 'admin');
  return new_team_id;
end;
$$;

-- Genera un link de invitación para un equipo — solo lo puede llamar un admin de ese equipo.
create or replace function create_invite(p_team_id uuid, p_max_uses int default null)
returns text
language plpgsql
security definer
as $$
declare
  new_token text;
begin
  if not is_team_admin(p_team_id) then
    raise exception 'Solo un administrador del equipo puede generar invitaciones.';
  end if;
  insert into invite_tokens (team_id, created_by, max_uses)
    values (p_team_id, auth.uid(), p_max_uses)
    returning token into new_token;
  return new_token;
end;
$$;

-- Canjea un token de invitación: valida vigencia/usos y agrega al usuario actual como member.
create or replace function redeem_invite(p_token text)
returns uuid
language plpgsql
security definer
as $$
declare
  inv record;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para usar esta invitación.';
  end if;
  select * into inv from invite_tokens where token = p_token;
  if not found then
    raise exception 'Invitación inválida.';
  end if;
  if inv.expires_at < now() then
    raise exception 'Esta invitación ya venció.';
  end if;
  if inv.max_uses is not null and inv.uses >= inv.max_uses then
    raise exception 'Esta invitación ya se usó el máximo de veces permitido.';
  end if;

  insert into memberships (team_id, user_id, role)
    values (inv.team_id, auth.uid(), 'member')
    on conflict (team_id, user_id) do nothing;

  update invite_tokens set uses = uses + 1 where id = inv.id;
  return inv.team_id;
end;
$$;
