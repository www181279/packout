-- ============================================================
-- Packout: database setup for Supabase
-- Run this ONCE: Supabase dashboard > SQL Editor > New query >
-- paste everything > Run. Safe to run again.
-- ============================================================

-- 1. Tables ---------------------------------------------------

create table if not exists public.pallets (
  id          bigint generated always as identity primary key,
  area        text not null default '',
  status      text not null default 'open' check (status in ('open','closed')),
  created_by  text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.boxes (
  id          bigint generated always as identity primary key,
  pallet_id   bigint not null references public.pallets(id) on delete restrict,
  status      text not null default 'open' check (status in ('open','closed')),
  created_by  text not null,
  created_at  timestamptz not null default now()
);

-- One row per style number. The primary key is what guarantees that a
-- style can only ever be assigned to ONE pallet, even if two employees
-- tap at the same moment: the second one is rejected by the database.
create table if not exists public.styles (
  style_number text primary key
               check (style_number <> '' and style_number = upper(btrim(style_number))),
  pallet_id    bigint not null references public.pallets(id) on delete restrict,
  created_by   text not null,
  created_at   timestamptz not null default now()
);

create table if not exists public.items (
  id           uuid primary key default gen_random_uuid(),
  style_number text not null references public.styles(style_number) on delete restrict,
  box_id       bigint not null references public.boxes(id) on delete restrict,
  pallet_id    bigint references public.pallets(id) on delete restrict,
  color        text not null,
  brand        text not null,
  tag_number   text not null default '',
  quantity     integer not null check (quantity > 0),
  gender       text not null,
  season       text not null,
  photo_path   text,
  created_by   text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists items_style_idx  on public.items (style_number);
create index if not exists items_box_idx    on public.items (box_id);
create index if not exists items_pallet_idx on public.items (pallet_id);
create index if not exists boxes_pallet_idx on public.boxes (pallet_id);

-- 2. Rules enforced by the database ---------------------------

-- An item can only be saved into a box that sits on its style's pallet.
create or replace function public.items_enforce_pallet()
returns trigger
language plpgsql
as $$
declare
  box_pallet   bigint;
  style_pallet bigint;
begin
  select pallet_id into box_pallet   from public.boxes  where id = new.box_id;
  select pallet_id into style_pallet from public.styles where style_number = new.style_number;
  if box_pallet is distinct from style_pallet then
    raise exception 'STYLE_PALLET_MISMATCH: style % belongs on pallet %, but box % is on pallet %',
      new.style_number, style_pallet, new.box_id, box_pallet;
  end if;
  new.pallet_id  := box_pallet;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists items_enforce_pallet on public.items;
create trigger items_enforce_pallet
  before insert or update on public.items
  for each row execute function public.items_enforce_pallet();

-- A box or a style that already has items cannot be moved to another pallet.
create or replace function public.lock_pallet_once_used()
returns trigger
language plpgsql
as $$
begin
  if new.pallet_id is distinct from old.pallet_id then
    if tg_table_name = 'boxes' and exists (select 1 from public.items where box_id = old.id) then
      raise exception 'This box already has items and cannot move to another pallet';
    end if;
    if tg_table_name = 'styles' and exists (select 1 from public.items where style_number = old.style_number) then
      raise exception 'This style already has items and cannot move to another pallet';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists boxes_lock_pallet on public.boxes;
create trigger boxes_lock_pallet
  before update on public.boxes
  for each row execute function public.lock_pallet_once_used();

drop trigger if exists styles_lock_pallet on public.styles;
create trigger styles_lock_pallet
  before update on public.styles
  for each row execute function public.lock_pallet_once_used();

-- 3. Access for the app ---------------------------------------
-- The app has no logins: anyone who has your invite link can read and
-- write the inventory. Share the link only with your employees.

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete
  on public.pallets, public.boxes, public.styles, public.items
  to anon, authenticated;

alter table public.pallets enable row level security;
alter table public.boxes   enable row level security;
alter table public.styles  enable row level security;
alter table public.items   enable row level security;

drop policy if exists "packout pallets" on public.pallets;
create policy "packout pallets" on public.pallets for all to anon, authenticated using (true) with check (true);
drop policy if exists "packout boxes" on public.boxes;
create policy "packout boxes" on public.boxes for all to anon, authenticated using (true) with check (true);
drop policy if exists "packout styles" on public.styles;
create policy "packout styles" on public.styles for all to anon, authenticated using (true) with check (true);
drop policy if exists "packout items" on public.items;
create policy "packout items" on public.items for all to anon, authenticated using (true) with check (true);

-- 4. Photo storage --------------------------------------------

insert into storage.buckets (id, name, public)
values ('item-photos', 'item-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "packout photos read" on storage.objects;
create policy "packout photos read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'item-photos');
drop policy if exists "packout photos upload" on storage.objects;
create policy "packout photos upload" on storage.objects
  for insert to anon, authenticated with check (bucket_id = 'item-photos');
drop policy if exists "packout photos replace" on storage.objects;
create policy "packout photos replace" on storage.objects
  for update to anon, authenticated using (bucket_id = 'item-photos') with check (bucket_id = 'item-photos');

-- Tell the API about the new tables right away.
notify pgrst, 'reload schema';
