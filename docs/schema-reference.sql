-- ============================================================================
-- RANCH Bakery Operational Dashboard — Schema Reference
-- Pulled directly from the live Supabase project (yhrqzgcvxzezaakduvey,
-- us-east-2) on 2026-08-09. This is a READ REFERENCE, not a migration file —
-- it documents what exists right now so you don't have to reverse-engineer
-- it later. Row-level security (RLS) is ON for every table below.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- TABLES
-- ----------------------------------------------------------------------------

-- products (17 rows) — what you sell
create table public.products (
  id             bigint generated always as identity primary key,
  name           text not null,
  description    text,
  base_price     numeric default 0,
  cost_of_goods  numeric default 0,
  stock_qty      integer default 0,
  created_at     timestamptz default now()
);

-- customers (17 rows) — one row per known customer, matched by email
create table public.customers (
  id                       uuid primary key default gen_random_uuid(),
  name                     text not null,
  email                    text not null unique,
  phone                    text,
  fulfillment_preference   text default 'pickup',
  delivery_location        text,
  created_at               timestamptz default now()
);

-- orders (43 rows) — the core order record
create table public.orders (
  id                bigint generated always as identity primary key,
  customer_id       uuid references public.customers(id),
  customer_name     text,
  customer_email    text,
  customer_phone    text,
  fulfillment       text default 'pickup',       -- 'pickup' | 'delivery'
  delivery_location text,                        -- school name, delivery only
  requested_date    date,
  notes             text,
  total             numeric default 0,
  status            text default 'pending',      -- pending|confirmed|baking|ready|fulfilled|cancelled
  payment_method    text,
  created_at        timestamptz default now(),
  delivery_date     date,                         -- auto-computed to next valid Tuesday; see trigger below
  discount_amount   numeric not null default 0,
  discount_reason   text
);

-- order_items (68 rows) — line items per order
create table public.order_items (
  id           bigint generated always as identity primary key,
  order_id     bigint references public.orders(id),
  product_id   bigint references public.products(id),
  product_name text,
  quantity     integer not null,
  unit_price   numeric,
  subtotal     numeric
);

-- order_status_log (20 rows) — full audit trail of every status change
create table public.order_status_log (
  id          bigint generated always as identity primary key,
  order_id    bigint not null references public.orders(id),
  old_status  text,
  new_status  text not null,
  reason      text,                      -- required when changed from the dashboard
  changed_by  text,                      -- email of whoever made the change, or 'system'
  source      text not null default 'direct',  -- 'dashboard' (reason logged) | 'direct' (changed elsewhere)
  created_at  timestamptz not null default now()
);

-- alerts (0 rows currently) — auto-generated, dismissible notices
create table public.alerts (
  id         bigint generated always as identity primary key,
  type       text,                       -- 'high_value' | 'reward_reminder'
  message    text,
  order_id   bigint references public.orders(id),
  resolved   boolean default false,
  created_at timestamptz default now()
);

-- communications (0 rows currently) — log of customer-facing messages sent
create table public.communications (
  id          bigint generated always as identity primary key,
  customer_id uuid references public.customers(id),
  order_id    bigint references public.orders(id),
  type        text,
  message     text,
  sent_at     timestamptz default now()
);

-- customer_rewards (2 rows) — punch-card ledger, one row per milestone earned
create table public.customer_rewards (
  id                 bigint generated always as identity primary key,
  customer_id        uuid not null references public.customers(id),
  milestone          integer not null,           -- 10, 20, 30... (points)
  earned_at          timestamptz not null default now(),
  redeemed           boolean not null default false,
  redeemed_at        timestamptz,
  redeemed_order_id  bigint references public.orders(id),
  note               text,
  earned_email_sent  boolean not null default false
);

-- ----------------------------------------------------------------------------
-- ROW-LEVEL SECURITY POLICIES (who can do what, without logging in vs. after)
-- "public"/"anon" = your storefront's guest order form. "authenticated" = you.
-- ----------------------------------------------------------------------------

-- products:      public can SELECT; authenticated can INSERT/UPDATE
-- customers:     only authenticated can SELECT/INSERT/UPDATE (guests go through
--                the upsert_customer_self / lookup_customer_by_email RPCs instead,
--                which are scoped narrowly rather than opening the whole table)
-- orders:        only authenticated can SELECT/INSERT/UPDATE (guests go through
--                submit_guest_order instead)
-- order_items:   public can SELECT; authenticated can INSERT
-- order_status_log: only authenticated can SELECT (no public policy at all)
-- alerts:        public can SELECT; authenticated can INSERT/UPDATE
-- communications: public can SELECT; authenticated can INSERT
-- customer_rewards: only authenticated can SELECT/UPDATE

-- ----------------------------------------------------------------------------
-- FUNCTIONS & TRIGGERS (the business logic that lives in the database, not
-- just the dashboard UI — so it holds even for edits made directly in Supabase)
-- ----------------------------------------------------------------------------

-- Assigns every new order to the next valid Tuesday. Cutoff is the Friday
-- before, 8:00 PM Eastern — past that, it rolls to the following Tuesday.
-- Skipped if the dashboard (authenticated) already set delivery_date itself.
CREATE OR REPLACE FUNCTION public.compute_order_delivery_date()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  tz constant text := 'America/New_York';
  today date;
  dow int;
  offset_days int;
  next_tue date;
  cutoff_ts timestamptz;
begin
  if auth.role() = 'authenticated' and new.delivery_date is not null then
    return new;
  end if;

  today := (now() at time zone tz)::date;
  dow := extract(dow from today)::int; -- Sunday = 0 ... Tuesday = 2 ... Saturday = 6
  offset_days := (2 - dow + 7) % 7;
  next_tue := today + offset_days;

  cutoff_ts := ((next_tue - 4)::text || ' 20:00:00')::timestamp at time zone tz;

  if now() > cutoff_ts then
    next_tue := next_tue + 7;
  end if;

  new.delivery_date := next_tue;
  return new;
end;
$function$;

-- $10 of FULFILLED spend = 1 point. 10 points ($100) = 1 reward, auto-issued.
CREATE OR REPLACE FUNCTION public.check_punch_card_reward()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_spent numeric;
  v_target_rewards integer;
  v_existing_rewards integer;
  i integer;
begin
  if NEW.status = 'fulfilled' and (TG_OP = 'INSERT' or OLD.status is distinct from 'fulfilled') then
    v_customer_id := NEW.customer_id;
    if v_customer_id is null and NEW.customer_email is not null then
      select id into v_customer_id from public.customers where lower(email) = lower(NEW.customer_email) limit 1;
    end if;

    if v_customer_id is not null then
      select coalesce(sum(o.total), 0) into v_spent
      from public.orders o
      where o.status = 'fulfilled'
        and (
          o.customer_id = v_customer_id
          or (o.customer_id is null and lower(o.customer_email) = (select lower(email) from public.customers where id = v_customer_id))
        );

      v_target_rewards := floor(v_spent / 100)::integer;
      select count(*) into v_existing_rewards from public.customer_rewards where customer_id = v_customer_id;

      if v_target_rewards > v_existing_rewards then
        for i in (v_existing_rewards + 1)..v_target_rewards loop
          insert into public.customer_rewards (customer_id, milestone, note)
          values (v_customer_id, i * 10, i * 10 || ' points ($' || (i * 100) || ' spent)')
          on conflict (customer_id, milestone) do nothing;
        end loop;
      end if;
    end if;
  end if;
  return NEW;
end;
$function$;

-- Flags any order totaling $500+ (and not cancelled) into the alerts table.
CREATE OR REPLACE FUNCTION public.flag_high_value_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.total is not null and new.total >= 500
     and coalesce(new.status, 'pending') <> 'cancelled' then
    if not exists (
      select 1 from public.alerts
      where order_id = new.id and type = 'high_value'
    ) then
      insert into public.alerts (type, message, order_id, resolved)
      values ('high_value', 'High value order #' || new.id || ' — $' || new.total::text, new.id, false);
    end if;
  end if;
  return new;
end;
$function$;

-- Reminds you when a customer with an unredeemed reward places a new order.
CREATE OR REPLACE FUNCTION public.flag_reward_reminder()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_reward record;
begin
  v_customer_id := NEW.customer_id;
  if v_customer_id is null and NEW.customer_email is not null then
    select id into v_customer_id from public.customers where lower(email) = lower(NEW.customer_email) limit 1;
  end if;

  if v_customer_id is not null then
    for v_reward in
      select * from public.customer_rewards where customer_id = v_customer_id and redeemed = false
    loop
      if not exists (
        select 1 from public.alerts
        where order_id = NEW.id and type = 'reward_reminder' and message like '%milestone:' || v_reward.milestone || '%'
      ) then
        insert into public.alerts (type, message, order_id, resolved)
        values (
          'reward_reminder',
          NEW.customer_name || ' has an unredeemed reward (' || v_reward.milestone || ' pts / $' || (v_reward.milestone * 10) || ' spent) — apply it to this order if appropriate. [milestone:' || v_reward.milestone || ']',
          NEW.id, false
        );
      end if;
    end loop;
  end if;
  return NEW;
end;
$function$;

-- Writes to order_status_log whenever status changes. If p_reason came in via
-- update_order_status(), it's tagged source='dashboard'; a direct edit in
-- Supabase (no reason set) is tagged source='direct'.
CREATE OR REPLACE FUNCTION public.log_order_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_reason text;
  v_source text;
begin
  if TG_OP = 'UPDATE' and NEW.status is distinct from OLD.status then
    v_reason := nullif(current_setting('app.status_change_reason', true), '');
    v_source := case when v_reason is not null then 'dashboard' else 'direct' end;
    insert into public.order_status_log (order_id, old_status, new_status, reason, changed_by, source)
    values (NEW.id, OLD.status, NEW.status, v_reason, coalesce(auth.jwt() ->> 'email', 'system'), v_source);
  end if;
  return NEW;
end;
$function$;

-- The only 4 things a signed-out visitor (your storefront's guest order form)
-- can do. Each is deliberately narrow — none of them expose the full
-- customers/orders tables.

-- Look up a returning customer by email (used to pre-fill the guest form).
CREATE OR REPLACE FUNCTION public.lookup_customer_by_email(p_email text)
 RETURNS TABLE(id uuid, name text, email text, phone text, fulfillment_preference text, delivery_location text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select id, name, email, phone, fulfillment_preference, delivery_location
  from public.customers
  where email = p_email
  limit 1;
$function$;

-- Create or update a customer record for a guest submitting an order.
CREATE OR REPLACE FUNCTION public.upsert_customer_self(p_name text, p_email text, p_phone text, p_fulfillment_preference text, p_delivery_location text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
begin
  insert into public.customers (name, email, phone, fulfillment_preference, delivery_location)
  values (p_name, p_email, p_phone, p_fulfillment_preference, p_delivery_location)
  on conflict (email) do update set
    name = excluded.name, phone = excluded.phone,
    fulfillment_preference = excluded.fulfillment_preference,
    delivery_location = excluded.delivery_location
  returning id into v_id;
  return v_id;
end;
$function$;

-- Submit a guest order end-to-end (validates inputs, computes total, inserts
-- the order + its line items in one transaction).
CREATE OR REPLACE FUNCTION public.submit_guest_order(p_customer_id uuid, p_customer_name text, p_customer_email text, p_customer_phone text, p_fulfillment text, p_delivery_location text, p_requested_date date, p_notes text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order_id bigint;
  v_total numeric;
  v_delivery_date date;
begin
  if p_customer_name is null or btrim(p_customer_name) = '' then
    raise exception 'Customer name is required';
  end if;
  if p_customer_email is null or p_customer_email !~ '@' then
    raise exception 'A valid email is required';
  end if;
  if p_fulfillment = 'delivery' and (p_delivery_location is null or btrim(p_delivery_location) = '') then
    raise exception 'Delivery location is required for delivery orders';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one item is required';
  end if;

  select coalesce(sum((item->>'quantity')::numeric * (item->>'unit_price')::numeric), 0)
  into v_total
  from jsonb_array_elements(p_items) as item;

  insert into public.orders (
    customer_id, customer_name, customer_email, customer_phone,
    fulfillment, delivery_location, requested_date, delivery_date, notes, total, status
  ) values (
    p_customer_id, btrim(p_customer_name), lower(btrim(p_customer_email)), nullif(btrim(coalesce(p_customer_phone, '')), ''),
    p_fulfillment, nullif(btrim(coalesce(p_delivery_location, '')), ''), p_requested_date, p_requested_date,
    nullif(btrim(coalesce(p_notes, '')), ''), v_total, 'pending'
  )
  returning id, delivery_date into v_order_id, v_delivery_date;

  insert into public.order_items (order_id, product_id, product_name, quantity, unit_price, subtotal)
  select v_order_id, (item->>'product_id')::bigint, item->>'product_name',
         (item->>'quantity')::numeric, (item->>'unit_price')::numeric,
         (item->>'quantity')::numeric * (item->>'unit_price')::numeric
  from jsonb_array_elements(p_items) as item;

  return jsonb_build_object('order_id', v_order_id, 'total', v_total, 'delivery_date', v_delivery_date);
end;
$function$;

-- Used by the dashboard (never call orders.update status directly) so the
-- reason gets attached to the audit log via log_order_status_change() above.
CREATE OR REPLACE FUNCTION public.update_order_status(p_order_id bigint, p_new_status text, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.role() <> 'authenticated' then
    raise exception 'Not authorized';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to change order status.';
  end if;
  perform set_config('app.status_change_reason', p_reason, true);
  update public.orders set status = p_new_status where id = p_order_id;
end;
$function$;
