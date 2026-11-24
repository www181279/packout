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

-- Type of garment (Jeans, T-shirt, Hoodie...). Added later, so it is added to an existing table too.
alter table public.items add column if not exists item_type text not null default '';
-- Size (XS ... 3XL, One size, or anything typed such as 32 or 4T). One line per size.
alter table public.items add column if not exists size text not null default '';

create index if not exists items_style_idx  on public.items (style_number);
create index if not exists items_box_idx    on public.items (box_id);
create index if not exists items_pallet_idx on public.items (pallet_id);
create index if not exists boxes_pallet_idx on public.boxes (pallet_id);
create index if not exists items_updated_idx on public.items (updated_at);

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

-- Pallet and box numbers: always the lowest number not in use, so the
-- first pallet is 1 and a deleted (empty) box or pallet frees its number.
alter table public.pallets alter column id set generated by default;
alter table public.boxes   alter column id set generated by default;

-- Box numbers show their pallet: Pallet 1 has boxes 101-130, Pallet 2 has
-- 201-230, Pallet 12 has 1201-1230 (30 per pallet by default, from settings 'boxes_per_pallet').
create or replace function public.use_lowest_free_number()
returns trigger
language plpgsql
as $$
declare
  n   bigint;
  per int;
begin
  -- one at a time per table, so two phones never get the same number
  perform pg_advisory_xact_lock(hashtext('packout_' || tg_table_name));
  if tg_table_name = 'boxes' then
    per := coalesce((select (value #>> '{}')::int from public.settings where key = 'boxes_per_pallet'), 30);
    select min(g) into n
      from generate_series(new.pallet_id * 100 + 1, new.pallet_id * 100 + least(per, 99)) g
     where not exists (select 1 from public.boxes b where b.id = g);
    if n is null then
      raise exception 'Pallet % is full: it already has % boxes. Start a new pallet for the rest.', new.pallet_id, per;
    end if;
  else
    execute format(
      'select coalesce(min(s), 1) from (
         select 1 as s where not exists (select 1 from public.%1$I where id = 1)
         union all
         select t.id + 1 from public.%1$I t
          where not exists (select 1 from public.%1$I x where x.id = t.id + 1)
       ) q', tg_table_name) into n;
  end if;
  new.id := n;
  return new;
end;
$$;

drop trigger if exists pallets_number on public.pallets;
create trigger pallets_number
  before insert on public.pallets
  for each row execute function public.use_lowest_free_number();

drop trigger if exists boxes_number on public.boxes;
create trigger boxes_number
  before insert on public.boxes
  for each row execute function public.use_lowest_free_number();

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
      -- the whole box goes, but box numbers belong to their pallet, so it gets a number on the new pallet
      insert into public.boxes (pallet_id, created_by, status)
        select v_to, created_by, status from public.boxes where id = v_box.id returning id into v_new;
      update public.items set box_id = v_new where box_id = v_box.id;
      delete from public.boxes where id = v_box.id;
      v_moved := v_moved || jsonb_build_object('box', v_box.id, 'new_box', v_new, 'pieces', v_box.pieces);
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
  v_count  integer;
  v_pallet bigint;
begin
  select pallet_id into v_pallet from public.styles where style_number = p_style;
  delete from public.items where style_number = p_style;
  get diagnostics v_count = row_count;
  delete from public.styles where style_number = p_style;
  -- boxes this style emptied are removed by the items_tidy trigger; other
  -- empty boxes may be in use by another phone, so they are left alone
  return v_count;
end;
$$;

-- When the last item of a style or of a box is deleted, the style's pallet
-- claim and the empty box go too, so nothing is left behind and box numbers are freed.
create or replace function public.tidy_after_item_delete()
returns trigger
language plpgsql
as $$
begin
  if not exists (select 1 from public.items where style_number = old.style_number) then
    delete from public.styles where style_number = old.style_number;
  end if;
  if not exists (select 1 from public.items where box_id = old.box_id) then
    delete from public.boxes where id = old.box_id;
  end if;
  return null;
end;
$$;

drop trigger if exists items_tidy on public.items;
create trigger items_tidy
  after delete on public.items
  for each row execute function public.tidy_after_item_delete();

-- Save one item, optionally continuing into more boxes on the same pallet
-- ("this color needs another box"). Each extra box is created, gets a copy of
-- the item with its own quantity, and every box before the last is marked full.
-- All or nothing. Safe to repeat after a lost reply: rows already saved are reused.
create or replace function public.save_item(p jsonb, p_more jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_box    bigint := (p->>'box_id')::bigint;
  v_pallet bigint;
  v_prev   bigint;
  v_new    bigint;
  v_boxes  jsonb := '[]'::jsonb;
  m        jsonb;
begin
  insert into public.items (id, style_number, box_id, item_type, color, brand, tag_number, quantity, gender, season, photo_path, created_by)
  values ((p->>'id')::uuid, p->>'style_number', v_box, coalesce(p->>'item_type', ''), p->>'color', p->>'brand', coalesce(p->>'tag_number', ''),
          (p->>'quantity')::int, p->>'gender', p->>'season', p->>'photo_path', p->>'created_by')
  on conflict (id) do nothing;
  select pallet_id into v_pallet from public.boxes where id = v_box;
  v_prev := v_box;
  for m in select * from jsonb_array_elements(p_more) loop
    select box_id into v_new from public.items where id = (m->>'id')::uuid;
    if v_new is null then
      insert into public.boxes (pallet_id, created_by) values (v_pallet, p->>'created_by') returning id into v_new;
      insert into public.items (id, style_number, box_id, item_type, color, brand, tag_number, quantity, gender, season, photo_path, created_by)
      values ((m->>'id')::uuid, p->>'style_number', v_new, coalesce(p->>'item_type', ''), p->>'color', p->>'brand', coalesce(p->>'tag_number', ''),
              (m->>'qty')::int, p->>'gender', p->>'season', p->>'photo_path', p->>'created_by');
    end if;
    update public.boxes set status = 'closed' where id = v_prev;
    v_boxes := v_boxes || to_jsonb(v_new);
    v_prev := v_new;
  end loop;
  return jsonb_build_object('boxes', v_boxes);
end;
$$;

grant execute on function public.save_item(jsonb, jsonb) to anon, authenticated;

-- Save one color of a style: one line per size, all sharing the photo. If one
-- size continues into more boxes, those boxes are created as in save_item.
-- All or nothing, and safe to repeat after a lost reply.
create or replace function public.save_entry(p jsonb, p_sizes jsonb, p_more jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_box    bigint := (p->>'box_id')::bigint;
  v_pallet bigint;
  v_prev   bigint;
  v_new    bigint;
  v_size   text;
  v_tag    text;
  v_boxes  jsonb := '[]'::jsonb;
  z        jsonb;
  m        jsonb;
begin
  if jsonb_array_length(p_sizes) = 0 then
    raise exception 'Choose at least one size';
  end if;
  if jsonb_array_length(p_more) > 0 and jsonb_array_length(p_sizes) <> 1 then
    raise exception 'More boxes can only be added when one size is packed';
  end if;
  for z in select * from jsonb_array_elements(p_sizes) loop
    insert into public.items (id, style_number, box_id, item_type, size, color, brand, tag_number, quantity, gender, season, photo_path, created_by)
    values ((z->>'id')::uuid, p->>'style_number', v_box, coalesce(p->>'item_type', ''), coalesce(z->>'size', ''), p->>'color', p->>'brand',
            coalesce(z->>'tag_number', p->>'tag_number', ''), (z->>'qty')::int, p->>'gender', p->>'season', p->>'photo_path', p->>'created_by')
    on conflict (id) do nothing;
  end loop;
  v_size := coalesce(p_sizes->0->>'size', '');
  v_tag  := coalesce(p_sizes->0->>'tag_number', p->>'tag_number', '');
  select pallet_id into v_pallet from public.boxes where id = v_box;
  v_prev := v_box;
  for m in select * from jsonb_array_elements(p_more) loop
    select box_id into v_new from public.items where id = (m->>'id')::uuid;
    if v_new is null then
      insert into public.boxes (pallet_id, created_by) values (v_pallet, p->>'created_by') returning id into v_new;
      insert into public.items (id, style_number, box_id, item_type, size, color, brand, tag_number, quantity, gender, season, photo_path, created_by)
      values ((m->>'id')::uuid, p->>'style_number', v_new, coalesce(p->>'item_type', ''), v_size, p->>'color', p->>'brand',
              v_tag, (m->>'qty')::int, p->>'gender', p->>'season', p->>'photo_path', p->>'created_by');
    end if;
    update public.boxes set status = 'closed' where id = v_prev;
    v_boxes := v_boxes || to_jsonb(v_new);
    v_prev := v_new;
  end loop;
  return jsonb_build_object('boxes', v_boxes);
end;
$$;

grant execute on function public.save_entry(jsonb, jsonb, jsonb) to anon, authenticated;
grant execute on function public.move_style(text, bigint, text, text) to anon, authenticated;
grant execute on function public.rename_style(text, text) to anon, authenticated;
grant execute on function public.delete_style(text) to anon, authenticated;

-- 3. Access for the app ---------------------------------------
-- The app has no logins. Anyone with a link can READ the inventory.
-- Adding, changing and deleting needs the private team code, which is
-- only inside the employees' invite link (never in this file). The
-- manager's view-only link has no team code, so it can only look.
-- Until a team code is set, every link can write.

alter table public.items add column if not exists photo_pro boolean not null default false;

create table if not exists public.settings (
  key         text primary key,
  value       jsonb,
  updated_at  timestamptz not null default now()
);

create schema if not exists packout_private;
revoke all on schema packout_private from public, anon, authenticated;
create table if not exists packout_private.app_secret (
  id         int primary key default 1 check (id = 1),
  team_code  text
);
revoke all on packout_private.app_secret from public, anon, authenticated;

-- Staff sign-in (section 7) is created first so this rule can use it.
create extension if not exists pgcrypto with schema extensions;
create table if not exists packout_private.staff (
  name       text primary key,
  pin_hash   text not null,
  is_owner   boolean not null default false,
  active     boolean not null default true,
  failed     int not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists packout_private.sessions (
  token_hash text primary key,
  name       text not null references packout_private.staff(name) on delete cascade on update cascade,
  created_at timestamptz not null default now()
);
revoke all on packout_private.staff, packout_private.sessions from public, anon, authenticated;

create or replace function packout_private.header(h text)
returns text language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.headers', true), '')::json ->> h, '');
$$;

-- The team code from the invite link matches.
create or replace function packout_private.team_ok()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select s.team_code is null or s.team_code = '' or s.team_code = packout_private.header('x-packout-team')
                     from packout_private.app_secret s where s.id = 1), true);
$$;

-- The signed-in person on this phone, or null.
create or replace function packout_private.session_name()
returns text language sql stable security definer set search_path = '' as $$
  select st.name from packout_private.sessions se join packout_private.staff st on st.name = se.name
   where se.token_hash = encode(extensions.digest(packout_private.header('x-packout-session'), 'sha256'), 'hex')
     and st.active
     and packout_private.header('x-packout-session') <> '';
$$;

-- Writing needs the team code AND, once staff are set up, a signed-in person.
create or replace function public.packout_can_write()
returns boolean language sql stable security definer set search_path = '' as $$
  select packout_private.team_ok()
     and (not exists (select 1 from packout_private.staff) or packout_private.session_name() is not null);
$$;
revoke all on function public.packout_can_write() from public;
grant execute on function public.packout_can_write() to anon, authenticated;

-- Used by the server functions (tag reading, photo polishing) to check the caller.
create or replace function public.packout_is_team()
returns boolean language sql stable security invoker set search_path = '' as $$ select public.packout_can_write(); $$;
grant execute on function public.packout_is_team() to anon, authenticated;

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete
  on public.pallets, public.boxes, public.styles, public.items, public.settings
  to anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['pallets', 'boxes', 'styles', 'items', 'settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "packout %s" on public.%I', t, t);
    execute format('drop policy if exists "packout %s read" on public.%I', t, t);
    execute format('drop policy if exists "packout %s add" on public.%I', t, t);
    execute format('drop policy if exists "packout %s change" on public.%I', t, t);
    execute format('drop policy if exists "packout %s remove" on public.%I', t, t);
    execute format('create policy "packout %s read" on public.%I for select to anon, authenticated using (true)', t, t);
    execute format('create policy "packout %s add" on public.%I for insert to anon, authenticated with check (public.packout_can_write())', t, t);
    execute format('create policy "packout %s change" on public.%I for update to anon, authenticated using (public.packout_can_write()) with check (public.packout_can_write())', t, t);
    execute format('create policy "packout %s remove" on public.%I for delete to anon, authenticated using (public.packout_can_write())', t, t);
  end loop;
end;
$$;

-- 4. Photo storage --------------------------------------------

insert into storage.buckets (id, name, public)
values ('item-photos', 'item-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "packout photos read" on storage.objects;
create policy "packout photos read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'item-photos');
drop policy if exists "packout photos upload" on storage.objects;
create policy "packout photos upload" on storage.objects
  for insert to anon, authenticated with check (bucket_id = 'item-photos' and public.packout_can_write());
drop policy if exists "packout photos replace" on storage.objects;
create policy "packout photos replace" on storage.objects
  for update to anon, authenticated using (bucket_id = 'item-photos' and public.packout_can_write()) with check (bucket_id = 'item-photos' and public.packout_can_write());
drop policy if exists "packout photos delete" on storage.objects;
create policy "packout photos delete" on storage.objects
  for delete to anon, authenticated using (bucket_id = 'item-photos' and public.packout_can_write());

-- 5. Live updates: every phone hears about changes within a second.
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['pallets', 'boxes', 'styles', 'items', 'settings'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;


-- 6. Change history -------------------------------------------
-- Every add, change and delete is copied here, with the phone's name and time,
-- so mistakes or deliberate damage can be traced and undone. Phones cannot read
-- or erase it; only the owner sees it in the Supabase dashboard.
create table if not exists packout_private.history (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  tbl       text not null,
  op        text not null,
  by_name   text,
  old_row   jsonb,
  new_row   jsonb
);
revoke all on packout_private.history from public, anon, authenticated;

create or replace function packout_private.record_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_by text := coalesce(packout_private.session_name(), nullif(current_setting('request.headers', true), '')::json ->> 'x-packout-name');
begin
  insert into packout_private.history (tbl, op, by_name, old_row, new_row)
  values (tg_table_name, tg_op, v_by,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return null;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['pallets', 'boxes', 'styles', 'items', 'settings'] loop
    execute format('drop trigger if exists packout_history on public.%I', t);
    execute format('create trigger packout_history after insert or update or delete on public.%I for each row execute function packout_private.record_change()', t);
  end loop;
end;
$$;


-- 7. Staff sign-in --------------------------------------------
-- Each person signs in once per phone with their name and a 6-digit PIN.
-- PINs are stored scrambled (bcrypt). 5 wrong tries lock the name until the owner unlocks it.

create or replace function public.packout_staff_names()
returns setof text language sql stable security definer set search_path = '' as $$
  select name from packout_private.staff where active and packout_private.team_ok() order by name;
$$;

create or replace function public.packout_login(p_name text, p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare st packout_private.staff; v_token text;
begin
  if not packout_private.team_ok() then raise exception 'NOT_TEAM' using errcode = '42501'; end if;
  select * into st from packout_private.staff where name = p_name for update;
  if not found or not st.active then raise exception 'NO_NAME'; end if;
  if st.failed >= 5 then raise exception 'LOCKED'; end if;
  if st.pin_hash <> extensions.crypt(coalesce(p_pin, ''), st.pin_hash) then
    update packout_private.staff set failed = failed + 1 where name = p_name;
    return jsonb_build_object('ok', false, 'left', greatest(0, 4 - st.failed));
  end if;
  update packout_private.staff set failed = 0 where name = p_name;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into packout_private.sessions (token_hash, name) values (encode(extensions.digest(v_token, 'sha256'), 'hex'), p_name);
  return jsonb_build_object('ok', true, 'token', v_token, 'name', st.name, 'owner', st.is_owner);
end;
$$;

create or replace function public.packout_whoami()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when n is null then null else jsonb_build_object('name', n, 'owner', (select is_owner from packout_private.staff where name = n)) end
    from (select packout_private.session_name() as n) q;
$$;

create or replace function public.packout_logout()
returns void language sql volatile security definer set search_path = '' as $$
  delete from packout_private.sessions where token_hash = encode(extensions.digest(packout_private.header('x-packout-session'), 'sha256'), 'hex');
$$;

-- Owner only: list, add, change PIN, turn on/off, unlock.
create or replace function packout_private.require_owner()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not packout_private.team_ok() or not coalesce((select is_owner from packout_private.staff where name = packout_private.session_name()), false) then
    raise exception 'OWNER_ONLY' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.packout_staff_list()
returns table (name text, is_owner boolean, active boolean, locked boolean, phones bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform packout_private.require_owner();
  return query select s.name, s.is_owner, s.active, s.failed >= 5, (select count(*) from packout_private.sessions x where x.name = s.name)
                 from packout_private.staff s order by s.is_owner desc, s.name;
end;
$$;

create or replace function public.packout_staff_save(p_name text, p_pin text default null, p_active boolean default null, p_unlock boolean default false)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_name text := btrim(p_name);
begin
  perform packout_private.require_owner();
  if v_name = '' then raise exception 'Type a name'; end if;
  if p_pin is not null and p_pin !~ '^[0-9]{6}$' then raise exception 'The PIN must be 6 digits'; end if;
  if exists (select 1 from packout_private.staff where name = v_name) then
    if v_name = packout_private.session_name() and p_active is false then raise exception 'You cannot turn off your own name'; end if;
    update packout_private.staff set
      pin_hash = coalesce(extensions.crypt(p_pin, extensions.gen_salt('bf', 8)), pin_hash),
      active   = coalesce(p_active, active),
      failed   = case when p_unlock or p_pin is not null then 0 else failed end
     where name = v_name;
    -- a new PIN or turning someone off signs them out on every phone
    if p_pin is not null or p_active is false then delete from packout_private.sessions where name = v_name; end if;
  else
    if p_pin is null then raise exception 'A new person needs a PIN'; end if;
    insert into packout_private.staff (name, pin_hash) values (v_name, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)));
  end if;
end;
$$;

revoke all on function public.packout_login(text, text), public.packout_staff_save(text, text, boolean, boolean), public.packout_staff_list(),
  public.packout_logout(), public.packout_whoami(), public.packout_staff_names() from public;
grant execute on function public.packout_login(text, text), public.packout_staff_save(text, text, boolean, boolean), public.packout_staff_list(),
  public.packout_logout(), public.packout_whoami(), public.packout_staff_names() to anon, authenticated;

-- The signed-in name is what gets saved as "packed by", whatever the phone sends.
create or replace function packout_private.stamp_creator()
returns trigger language plpgsql security definer set search_path = '' as $$
declare n text := packout_private.session_name();
begin
  if n is not null then new.created_by := n; end if;
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['pallets', 'boxes', 'styles', 'items'] loop
    execute format('drop trigger if exists packout_stamp on public.%I', t);
    execute format('create trigger packout_stamp before insert on public.%I for each row execute function packout_private.stamp_creator()', t);
  end loop;
end;
$$;

-- Tell the API about the new tables right away.
notify pgrst, 'reload schema';
-- 8. Face ID sign-in (passkeys). The phone keeps a private key behind Face ID; the database keeps only the public key.
create table if not exists packout_private.passkeys (
  cred_id    text primary key,
  name       text not null references packout_private.staff(name) on delete cascade on update cascade,
  public_key text not null,            -- base64 SPKI, P-256 (ES256)
  created_at timestamptz not null default now(),
  last_used  timestamptz
);
create table if not exists packout_private.passkey_challenges (
  challenge  text primary key,
  created_at timestamptz not null default now()
);
revoke all on packout_private.passkeys, packout_private.passkey_challenges from public, anon, authenticated;

create or replace function packout_private.b64u(b bytea)
returns text language sql immutable set search_path = '' as $$
  select rtrim(translate(encode(b, 'base64'), E'+/\n', '-_'), '=');
$$;

-- The signed-in person turns on Face ID for this phone.
create or replace function public.packout_passkey_add(p_cred_id text, p_public_key text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v_name text := packout_private.session_name();
begin
  if v_name is null or not packout_private.team_ok() then raise exception 'NOT_SIGNED_IN' using errcode = '42501'; end if;
  if p_cred_id !~ '^[A-Za-z0-9_-]+$' or length(p_cred_id) not between 16 and 512 or length(p_public_key) not between 60 and 400 then raise exception 'BAD_KEY'; end if;
  insert into packout_private.passkeys (cred_id, name, public_key) values (p_cred_id, v_name, p_public_key)
  on conflict (cred_id) do update set name = excluded.name, public_key = excluded.public_key, created_at = now();
end;
$$;

create or replace function public.packout_passkey_remove(p_cred_id text)
returns void language sql volatile security definer set search_path = '' as $$
  delete from packout_private.passkeys where cred_id = p_cred_id and name = packout_private.session_name();
$$;

-- A one-time challenge for a Face ID sign-in (good for 5 minutes).
create or replace function public.packout_passkey_challenge()
returns text language plpgsql volatile security definer set search_path = '' as $$
declare v text := packout_private.b64u(extensions.gen_random_bytes(32));
begin
  if not packout_private.team_ok() then raise exception 'NOT_TEAM' using errcode = '42501'; end if;
  delete from packout_private.passkey_challenges where created_at < now() - interval '5 minutes';
  insert into packout_private.passkey_challenges (challenge) values (v);
  return v;
end;
$$;

-- Used only by the passkey-login function (service role): the public key to check the signature against ...
create or replace function public.packout_passkey_key(p_cred_id text)
returns text language sql stable security definer set search_path = '' as $$
  select public_key from packout_private.passkeys where cred_id = p_cred_id;
$$;
-- ... and, once the signature is good, a new session for that person.
create or replace function public.packout_passkey_finish(p_cred_id text, p_challenge text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare st packout_private.staff; v_token text;
begin
  delete from packout_private.passkey_challenges where challenge = p_challenge and created_at > now() - interval '5 minutes';
  if not found then raise exception 'EXPIRED'; end if;
  select s.* into st from packout_private.passkeys k join packout_private.staff s on s.name = k.name where k.cred_id = p_cred_id;
  if not found then raise exception 'NO_KEY'; end if;
  if not st.active then raise exception 'NO_NAME'; end if;
  if st.failed >= 5 then raise exception 'LOCKED'; end if;
  update packout_private.passkeys set last_used = now() where cred_id = p_cred_id;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into packout_private.sessions (token_hash, name) values (encode(extensions.digest(v_token, 'sha256'), 'hex'), st.name);
  return jsonb_build_object('ok', true, 'token', v_token, 'name', st.name, 'owner', st.is_owner);
end;
$$;

revoke all on function public.packout_passkey_add(text, text), public.packout_passkey_remove(text), public.packout_passkey_challenge(),
  public.packout_passkey_key(text), public.packout_passkey_finish(text, text) from public, anon, authenticated;
grant execute on function public.packout_passkey_add(text, text), public.packout_passkey_remove(text), public.packout_passkey_challenge() to anon, authenticated;
grant execute on function public.packout_passkey_key(text), public.packout_passkey_finish(text, text) to service_role;

-- A new PIN or turning someone off also removes their Face ID on every phone.
create or replace function packout_private.passkeys_follow_staff()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.pin_hash is distinct from old.pin_hash or (old.active and not new.active) then
    delete from packout_private.passkeys where name = new.name;
  end if;
  return new;
end;
$$;
drop trigger if exists passkeys_follow_staff on packout_private.staff;
create trigger passkeys_follow_staff after update on packout_private.staff for each row execute function packout_private.passkeys_follow_staff();
-- 9. People who can pack and edit but not delete (for example a Guest login for managers).
alter table packout_private.staff add column if not exists can_delete boolean not null default true;

create or replace function public.packout_can_delete()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.packout_can_write()
     and coalesce((select s.can_delete from packout_private.staff s where s.name = packout_private.session_name()), true);
$$;
revoke all on function public.packout_can_delete() from public;
grant execute on function public.packout_can_delete() to anon, authenticated;

-- Deleting: items, pallets and settings need delete rights. An empty style claim or an empty box
-- may still be tidied away by anyone who can write (moving and renaming styles do this).
do $$
declare t text;
begin
  foreach t in array array['pallets', 'items', 'settings'] loop
    execute format('drop policy if exists "packout %s remove" on public.%I', t, t);
    execute format('create policy "packout %s remove" on public.%I for delete to anon, authenticated using (public.packout_can_delete())', t, t);
  end loop;
end $$;
drop policy if exists "packout styles remove" on public.styles;
create policy "packout styles remove" on public.styles for delete to anon, authenticated
  using (public.packout_can_delete() or (public.packout_can_write() and not exists (select 1 from public.items i where i.style_number = styles.style_number)));
drop policy if exists "packout boxes remove" on public.boxes;
create policy "packout boxes remove" on public.boxes for delete to anon, authenticated
  using (public.packout_can_delete() or (public.packout_can_write() and not exists (select 1 from public.items i where i.box_id = boxes.id)));
drop policy if exists "packout photos delete" on storage.objects;
create policy "packout photos delete" on storage.objects
  for delete to anon, authenticated using (bucket_id = 'item-photos' and public.packout_can_delete());

-- Sign-in answers say whether this person may delete.
create or replace function public.packout_login(p_name text, p_pin text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare st packout_private.staff; v_token text;
begin
  if not packout_private.team_ok() then raise exception 'NOT_TEAM' using errcode = '42501'; end if;
  select * into st from packout_private.staff where name = p_name for update;
  if not found or not st.active then raise exception 'NO_NAME'; end if;
  if st.failed >= 5 then raise exception 'LOCKED'; end if;
  if st.pin_hash <> extensions.crypt(coalesce(p_pin, ''), st.pin_hash) then
    update packout_private.staff set failed = failed + 1 where name = p_name;
    return jsonb_build_object('ok', false, 'left', greatest(0, 4 - st.failed));
  end if;
  update packout_private.staff set failed = 0 where name = p_name;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into packout_private.sessions (token_hash, name) values (encode(extensions.digest(v_token, 'sha256'), 'hex'), p_name);
  return jsonb_build_object('ok', true, 'token', v_token, 'name', st.name, 'owner', st.is_owner, 'del', st.can_delete);
end;
$$;
create or replace function public.packout_whoami()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when n is null then null else (select jsonb_build_object('name', s.name, 'owner', s.is_owner, 'del', s.can_delete) from packout_private.staff s where s.name = n) end
    from (select packout_private.session_name() as n) q;
$$;
create or replace function public.packout_passkey_finish(p_cred_id text, p_challenge text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare st packout_private.staff; v_token text;
begin
  delete from packout_private.passkey_challenges where challenge = p_challenge and created_at > now() - interval '5 minutes';
  if not found then raise exception 'EXPIRED'; end if;
  select s.* into st from packout_private.passkeys k join packout_private.staff s on s.name = k.name where k.cred_id = p_cred_id;
  if not found then raise exception 'NO_KEY'; end if;
  if not st.active then raise exception 'NO_NAME'; end if;
  if st.failed >= 5 then raise exception 'LOCKED'; end if;
  update packout_private.passkeys set last_used = now() where cred_id = p_cred_id;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into packout_private.sessions (token_hash, name) values (encode(extensions.digest(v_token, 'sha256'), 'hex'), st.name);
  return jsonb_build_object('ok', true, 'token', v_token, 'name', st.name, 'owner', st.is_owner, 'del', st.can_delete);
end;
$$;
revoke all on function public.packout_passkey_finish(text, text) from public, anon, authenticated;
grant execute on function public.packout_passkey_finish(text, text) to service_role;

-- Owner: see and switch delete rights.
drop function if exists public.packout_staff_list();
create function public.packout_staff_list()
returns table (name text, is_owner boolean, active boolean, locked boolean, phones bigint, can_delete boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform packout_private.require_owner();
  return query select s.name, s.is_owner, s.active, s.failed >= 5, (select count(*) from packout_private.sessions x where x.name = s.name), s.can_delete
                 from packout_private.staff s order by s.is_owner desc, s.name;
end;
$$;
create or replace function public.packout_staff_delete_rights(p_name text, p_can boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  perform packout_private.require_owner();
  update packout_private.staff set can_delete = p_can where name = p_name and not is_owner;
end;
$$;
revoke all on function public.packout_staff_list(), public.packout_staff_delete_rights(text, boolean) from public;
grant execute on function public.packout_staff_list(), public.packout_staff_delete_rights(text, boolean) to anon, authenticated;
-- 10. Short invite links: https://…/packout/?j=CODE. The code is swapped for the team code here.
alter table packout_private.app_secret add column if not exists join_code text;
update packout_private.app_secret
   set join_code = (select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + get_byte(extensions.gen_random_bytes(1), 0) % 31, 1), '') from generate_series(1, 8))
 where id = 1 and join_code is null;

create or replace function public.packout_join(p_code text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare v text;
begin
  perform pg_sleep(0.3);      -- slows down anyone guessing codes
  select s.team_code into v from packout_private.app_secret s
   where s.id = 1 and s.join_code is not null and s.join_code = upper(btrim(coalesce(p_code, '')));
  return v;
end;
$$;
create or replace function public.packout_join_code()
returns text language plpgsql stable security definer set search_path = '' as $$
begin
  perform packout_private.require_owner();
  return (select join_code from packout_private.app_secret where id = 1);
end;
$$;
revoke all on function public.packout_join(text), public.packout_join_code() from public;
grant execute on function public.packout_join(text), public.packout_join_code() to anon, authenticated;
select join_code from packout_private.app_secret where id = 1;
-- 11. Guests (can_delete = false) can pack new items only: no edits, no deletes, no settings.
create or replace function packout_private.is_guest()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select not s.can_delete from packout_private.staff s where s.name = packout_private.session_name()), false);
$$;

-- Saved items: a guest may only mark a photo as polished (the app does this on its own).
create or replace function packout_private.guest_item_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if packout_private.is_guest() and (to_jsonb(new) - 'photo_pro' - 'updated_at') is distinct from (to_jsonb(old) - 'photo_pro' - 'updated_at') then
    raise exception 'Guests can''t change saved items.' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists guest_item_guard on public.items;
create trigger guest_item_guard before update on public.items for each row execute function packout_private.guest_item_guard();

-- Styles and pallets: no moving, renaming, closing or reopening for guests. Boxes: closing a full box is part of packing.
create or replace function packout_private.guest_no_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if packout_private.is_guest() then
    raise exception 'Guests can''t change saved items.' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists guest_no_update on public.styles;
create trigger guest_no_update before update on public.styles for each row execute function packout_private.guest_no_update();
drop trigger if exists guest_no_update on public.pallets;
create trigger guest_no_update before update on public.pallets for each row execute function packout_private.guest_no_update();

-- Settings: only people with full access.
drop policy if exists "packout settings add" on public.settings;
create policy "packout settings add" on public.settings for insert to anon, authenticated with check (public.packout_can_delete());
drop policy if exists "packout settings change" on public.settings;
create policy "packout settings change" on public.settings for update to anon, authenticated using (public.packout_can_delete()) with check (public.packout_can_delete());
-- 12. Only the owner changes settings and removes people.
create or replace function public.packout_is_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select packout_private.team_ok()
     and coalesce((select s.is_owner from packout_private.staff s where s.name = packout_private.session_name()), false);
$$;
revoke all on function public.packout_is_owner() from public;
grant execute on function public.packout_is_owner() to anon, authenticated;

drop policy if exists "packout settings add" on public.settings;
create policy "packout settings add" on public.settings for insert to anon, authenticated with check (public.packout_is_owner());
drop policy if exists "packout settings change" on public.settings;
create policy "packout settings change" on public.settings for update to anon, authenticated using (public.packout_is_owner()) with check (public.packout_is_owner());
drop policy if exists "packout settings remove" on public.settings;
create policy "packout settings remove" on public.settings for delete to anon, authenticated using (public.packout_is_owner());

create or replace function public.packout_staff_remove(p_name text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  perform packout_private.require_owner();
  delete from packout_private.staff where name = p_name and not is_owner;   -- sessions and Face ID go with it
end;
$$;
revoke all on function public.packout_staff_remove(text) from public;
grant execute on function public.packout_staff_remove(text) to anon, authenticated;

-- 13. Box numbers start at 1. Pallet 1 has boxes 1-30, Pallet 2 has 31-60, Pallet 3 has 61-90
--     (30 per pallet by default, from settings 'boxes_per_pallet'). Boxes already numbered the old
--     way (101, 102 ... 201 ...) are renumbered, and their items follow them.
do $$
declare c text;
begin
  select conname into c from pg_constraint where conrelid = 'public.items'::regclass and contype = 'f'
     and confrelid = 'public.boxes'::regclass;
  if c is not null then execute format('alter table public.items drop constraint %I', c); end if;
  alter table public.items add constraint items_box_id_fkey foreign key (box_id)
    references public.boxes(id) on delete restrict on update cascade;
end $$;

create or replace function public.use_lowest_free_number()
returns trigger
language plpgsql
as $$
declare
  n   bigint;
  per int;
begin
  -- one at a time per table, so two phones never get the same number
  perform pg_advisory_xact_lock(hashtext('packout_' || tg_table_name));
  if tg_table_name = 'boxes' then
    per := greatest(1, coalesce((select (value #>> '{}')::int from public.settings where key = 'boxes_per_pallet'), 30));
    select min(g) into n
      from generate_series((new.pallet_id - 1) * per + 1, new.pallet_id * per) g
     where not exists (select 1 from public.boxes b where b.id = g);
    if n is null then
      raise exception 'Pallet % is full: it already has % boxes. Start a new pallet for the rest.', new.pallet_id, per;
    end if;
  else
    execute format(
      'select coalesce(min(s), 1) from (
         select 1 as s where not exists (select 1 from public.%1$I where id = 1)
         union all
         select t.id + 1 from public.%1$I t
          where not exists (select 1 from public.%1$I x where x.id = t.id + 1)
       ) q', tg_table_name) into n;
  end if;
  new.id := n;
  return new;
end;
$$;

do $$
declare per int := greatest(1, coalesce((select (value #>> '{}')::int from public.settings where key = 'boxes_per_pallet'), 30));
begin
  -- move old-style numbers out of the way first, then give each its new number
  update public.boxes set id = id + 1000000 where id between pallet_id * 100 + 1 and pallet_id * 100 + 99;
  update public.boxes set id = (pallet_id - 1) * per + (id - 1000000 - pallet_id * 100) where id > 1000000;
end $$;

-- 14. A photo used again (same style and color) keeps its polished version: new rows that reuse a
--     polished photo are marked polished too, and rows saved before this fix are corrected.
create or replace function packout_private.photo_pro_follows()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.photo_path is not null and not coalesce(new.photo_pro, false)
     and exists (select 1 from public.items i where i.photo_path = new.photo_path and i.photo_pro) then
    new.photo_pro := true;
  end if;
  return new;
end;
$$;
drop trigger if exists items_photo_pro_follows on public.items;
create trigger items_photo_pro_follows before insert on public.items
  for each row execute function packout_private.photo_pro_follows();

update public.items i set photo_pro = true
 where not coalesce(i.photo_pro, false) and i.photo_path is not null
   and exists (select 1 from public.items x where x.photo_path = i.photo_path and x.photo_pro);

-- 15. New boxes take the next number in order on their pallet (after the highest one there), so they
--     follow pre-printed labels. A packer can also ask for a specific number (the one on the label in
--     hand) through packout_new_box(pallet, number).
create or replace function public.use_lowest_free_number()
returns trigger
language plpgsql
as $$
declare
  n    bigint;
  per  int;
  lo   bigint;
  hi   bigint;
  want bigint;
begin
  perform pg_advisory_xact_lock(hashtext('packout_' || tg_table_name));
  if tg_table_name = 'boxes' then
    per := greatest(1, coalesce((select (value #>> '{}')::int from public.settings where key = 'boxes_per_pallet'), 30));
    lo := (new.pallet_id - 1) * per + 1; hi := new.pallet_id * per;
    want := nullif(current_setting('packout.box_no', true), '')::bigint;
    if want is not null then
      if want < lo or want > hi then
        raise exception 'Box % is not on Pallet %. Pallet % uses boxes % to %.', want, new.pallet_id, new.pallet_id, lo, hi using errcode = 'P0001';
      end if;
      if exists (select 1 from public.boxes b where b.id = want) then
        raise exception 'Box % already exists.', want using errcode = 'P0001';
      end if;
      n := want;
    else
      select coalesce(max(b.id), lo - 1) + 1 into n from public.boxes b where b.id between lo and hi;
      if n > hi then
        select min(g) into n from generate_series(lo, hi) g where not exists (select 1 from public.boxes b where b.id = g);
      end if;
      if n is null then
        raise exception 'Pallet % is full: it already has % boxes. Start a new pallet for the rest.', new.pallet_id, per;
      end if;
    end if;
  else
    execute format(
      'select coalesce(min(s), 1) from (
         select 1 as s where not exists (select 1 from public.%1$I where id = 1)
         union all
         select t.id + 1 from public.%1$I t
          where not exists (select 1 from public.%1$I x where x.id = t.id + 1)
       ) q', tg_table_name) into n;
  end if;
  new.id := n;
  return new;
end;
$$;

create or replace function public.packout_new_box(p_pallet bigint, p_no bigint default null, p_by text default null)
returns public.boxes
language plpgsql
as $$
declare r public.boxes;
begin
  perform set_config('packout.box_no', coalesce(p_no::text, ''), true);
  insert into public.boxes (pallet_id, created_by) values (p_pallet, coalesce(p_by, 'Packer')) returning * into r;
  perform set_config('packout.box_no', '', true);
  return r;
end;
$$;

-- 15. A new box gets the next number after the highest box on its pallet (Box 21 -> Box 22), so numbers
--     match labels printed in order. Gaps left by deleted boxes are only reused when the pallet's range is full.
create or replace function public.use_lowest_free_number()
returns trigger
language plpgsql
as $$
declare
  n   bigint;
  per int;
  lo  bigint;
  hi  bigint;
begin
  perform pg_advisory_xact_lock(hashtext('packout_' || tg_table_name));
  if tg_table_name = 'boxes' then
    per := greatest(1, coalesce((select (value #>> '{}')::int from public.settings where key = 'boxes_per_pallet'), 30));
    lo := (new.pallet_id - 1) * per + 1;  hi := new.pallet_id * per;
    select coalesce(max(id) + 1, lo) into n from public.boxes where id between lo and hi;
    if n > hi then
      select min(g) into n from generate_series(lo, hi) g where not exists (select 1 from public.boxes b where b.id = g);
    end if;
    if n is null then
      raise exception 'Pallet % is full: it already has % boxes. Start a new pallet for the rest.', new.pallet_id, per;
    end if;
  else
    execute format(
      'select coalesce(min(s), 1) from (
         select 1 as s where not exists (select 1 from public.%1$I where id = 1)
         union all
         select t.id + 1 from public.%1$I t
          where not exists (select 1 from public.%1$I x where x.id = t.id + 1)
       ) q', tg_table_name) into n;
  end if;
  new.id := n;
  return new;
end;
$$;
