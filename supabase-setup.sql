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
  -- move_style() below is the one approved way to change a pallet
  if coalesce(current_setting('packout.moving', true), '') = '1' then
    return new;
  end if;
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

-- Move a whole style to another pallet (existing, or a new one when
-- p_target is null). Boxes holding only this style move with it. Where a
-- box is shared with other styles, this style's entries go to a new box
-- on the target pallet. Everything happens together or not at all.
create or replace function public.move_style(p_style text, p_target bigint, p_area text, p_by text)
returns jsonb
language plpgsql
as $$
declare
  v_from   bigint;
  v_to     bigint := p_target;
  v_box    record;
  v_new    bigint;
  v_moved  jsonb := '[]'::jsonb;
  v_repack jsonb := '[]'::jsonb;
begin
  select pallet_id into v_from from public.styles where style_number = p_style for update;
  if not found then
    raise exception 'Style % was not found', p_style;
  end if;
  if v_to is null then
    insert into public.pallets (area, created_by) values (coalesce(p_area, ''), p_by) returning id into v_to;
  elsif not exists (select 1 from public.pallets where id = v_to) then
    raise exception 'That pallet was not found';
  end if;
  if v_to = v_from then
    raise exception 'Style % is already on that pallet', p_style;
  end if;

  perform set_config('packout.moving', '1', true);
  update public.styles set pallet_id = v_to where style_number = p_style;
  for v_box in
    select b.id,
           (select coalesce(sum(i.quantity), 0) from public.items i where i.box_id = b.id and i.style_number = p_style) as pieces,
           exists (select 1 from public.items i where i.box_id = b.id and i.style_number <> p_style) as mixed
    from public.boxes b
    where b.pallet_id = v_from
      and exists (select 1 from public.items i where i.box_id = b.id and i.style_number = p_style)
    order by b.id
  loop
    if v_box.mixed then
      insert into public.boxes (pallet_id, created_by) values (v_to, p_by) returning id into v_new;
      update public.items set box_id = v_new where box_id = v_box.id and style_number = p_style;
      v_repack := v_repack || jsonb_build_object('from_box', v_box.id, 'to_box', v_new, 'pieces', v_box.pieces);
    else
      update public.boxes set pallet_id = v_to where id = v_box.id;
      update public.items set box_id = box_id where box_id = v_box.id;
      v_moved := v_moved || jsonb_build_object('box', v_box.id, 'pieces', v_box.pieces);
    end if;
  end loop;
  perform set_config('packout.moving', '', true);

  return jsonb_build_object('from_pallet', v_from, 'to_pallet', v_to, 'moved_boxes', v_moved, 'repack', v_repack);
end;
$$;

-- Correct a style number everywhere it is used.
create or replace function public.rename_style(p_old text, p_new text)
returns void
language plpgsql
as $$
declare
  v_new text := upper(btrim(regexp_replace(p_new, '\s+', ' ', 'g')));
  v_other bigint;
begin
  if v_new = '' then
    raise exception 'The new style number is empty';
  end if;
  if v_new = p_old then
    return;
  end if;
  select pallet_id into v_other from public.styles where style_number = v_new;
  if found then
    raise exception 'STYLE_EXISTS: style % already exists on pallet %', v_new, v_other;
  end if;
  insert into public.styles (style_number, pallet_id, created_by, created_at)
    select v_new, pallet_id, created_by, created_at from public.styles where style_number = p_old;
  if not found then
    raise exception 'Style % was not found', p_old;
  end if;
  update public.items set style_number = v_new where style_number = p_old;
  delete from public.styles where style_number = p_old;
end;
$$;

-- Delete a style and every item recorded under it.
create or replace function public.delete_style(p_style text)
returns integer
language plpgsql
as $$
declare
  v_count integer;
begin
  delete from public.items where style_number = p_style;
  get diagnostics v_count = row_count;
  delete from public.styles where style_number = p_style;
  return v_count;
end;
$$;

grant execute on function public.move_style(text, bigint, text, text) to anon, authenticated;
grant execute on function public.rename_style(text, text) to anon, authenticated;
grant execute on function public.delete_style(text) to anon, authenticated;

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
