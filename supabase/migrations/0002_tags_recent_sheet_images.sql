-- Fiorente Chords — Fase 1 de mejoras: etiquetas, "usadas recientemente" y partituras en imagen.
-- Correr una sola vez en el SQL Editor de Supabase (el mismo proyecto donde ya corriste 0001_init.sql).

-- ============================================================
-- COLUMNAS NUEVAS EN songs
-- ============================================================
alter table songs add column if not exists tags text[] not null default '{}';
alter table songs add column if not exists last_used_at timestamptz;
alter table songs add column if not exists sheet_image_path text;

-- ============================================================
-- STORAGE: partituras en imagen/PDF, privado por equipo
-- ============================================================
-- Cada archivo se guarda con la ruta "{team_id}/{song_id}/{nombre}", así que la política
-- solo necesita mirar el primer segmento de la ruta (el team_id) y reusar is_team_member,
-- la misma función que ya protege songs/setlist_items.
insert into storage.buckets (id, name, public)
values ('sheet-images', 'sheet-images', false)
on conflict (id) do nothing;

alter table storage.objects enable row level security;

create policy sheet_images_team_select on storage.objects for select
  using (bucket_id = 'sheet-images' and is_team_member(((storage.foldername(name))[1])::uuid));
create policy sheet_images_team_insert on storage.objects for insert
  with check (bucket_id = 'sheet-images' and is_team_member(((storage.foldername(name))[1])::uuid));
create policy sheet_images_team_delete on storage.objects for delete
  using (bucket_id = 'sheet-images' and is_team_member(((storage.foldername(name))[1])::uuid));
