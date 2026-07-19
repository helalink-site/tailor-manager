-- ============================================================
-- TAILOR MANAGER — Supabase schema
-- Run this once in Supabase: Dashboard → SQL Editor → New query → Run
-- ============================================================

-- ---------- Staff (profile row per Supabase Auth user) ----------
create table staff (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  phone text unique not null,
  role text not null default 'staff' check (role in ('admin','staff')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- Customers ----------
create table customers (
  id bigint generated always as identity primary key,
  name text not null,
  phone text not null,
  created_at timestamptz not null default now()
);

-- ---------- Orders ----------
create table orders (
  id bigint generated always as identity primary key,
  customer_id bigint not null references customers(id),
  handled_by uuid not null references staff(id),
  date_received date not null default current_date,
  due_date date,
  garment_type text not null,
  material_type text,
  material_color text,
  measurements text,
  total_amount numeric not null default 0,
  status text not null default 'pending' check (status in ('pending','completed')),
  completed_at timestamptz
);

-- ---------- Payments ----------
create table payments (
  id bigint generated always as identity primary key,
  order_id bigint not null references orders(id) on delete cascade,
  amount numeric not null,
  method text not null default 'cash',
  recorded_by uuid not null references staff(id),
  created_at timestamptz not null default now()
);

-- ---------- Notification permissions (admin toggles per staff/event) ----------
create table notification_settings (
  id bigint generated always as identity primary key,
  staff_id uuid not null references staff(id) on delete cascade,
  event_type text not null,
  enabled boolean not null default true,
  unique (staff_id, event_type)
);

-- ---------- Notifications (delivered messages) ----------
create table notifications (
  id bigint generated always as identity primary key,
  staff_id uuid not null references staff(id) on delete cascade,
  event_type text not null,
  message text not null,
  order_id bigint references orders(id) on delete set null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------- System settings (single row) ----------
create table system_settings (
  id bigint generated always as identity primary key,
  system_name text not null default 'Tailor Manager',
  logo_url text,
  last_daily_reminder_date date
);
insert into system_settings (system_name) values ('Tailor Manager');


-- ============================================================
-- HELPER: is_admin() — security definer avoids RLS recursion
-- ============================================================
create or replace function is_admin() returns boolean as $$
  select exists(
    select 1 from staff where id = auth.uid() and role = 'admin' and active = true
  );
$$ language sql security definer stable;


-- ============================================================
-- NOTIFICATION ENGINE (runs inside Postgres, not the browser)
-- ============================================================
create or replace function notify_staff(p_event_type text, p_message text, p_order_id bigint, p_exclude uuid)
returns void as $$
begin
  insert into notifications (staff_id, event_type, message, order_id)
  select s.id, p_event_type, p_message, p_order_id
  from staff s
  where s.active = true
    and (p_exclude is null or s.id <> p_exclude)
    and coalesce(
      (select ns.enabled from notification_settings ns where ns.staff_id = s.id and ns.event_type = p_event_type),
      true
    );
end;
$$ language plpgsql security definer;


-- New order -> notify everyone else
create or replace function trg_new_order() returns trigger as $$
declare cust record;
begin
  select name, phone into cust from customers where id = new.customer_id;
  perform notify_staff('new_order',
    'New order for ' || cust.name || ' (' || cust.phone || ') — ' || new.garment_type,
    new.id, new.handled_by);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_new_order after insert on orders
for each row execute function trg_new_order();


-- Order marked completed -> notify everyone else
create or replace function trg_order_completed() returns trigger as $$
declare cust record;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    select name, phone into cust from customers where id = new.customer_id;
    perform notify_staff('order_completed',
      new.garment_type || ' for ' || cust.name || ' (' || cust.phone || ') marked complete.',
      new.id, new.handled_by);
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger on_order_status_change after update on orders
for each row execute function trg_order_completed();


-- Payment recorded -> notify everyone else with balance info
create or replace function trg_payment_received() returns trigger as $$
declare
  ord record;
  cust record;
  paid numeric;
  bal numeric;
  msg text;
begin
  select * into ord from orders where id = new.order_id;
  select name, phone into cust from customers where id = ord.customer_id;
  select coalesce(sum(amount),0) into paid from payments where order_id = new.order_id;
  bal := ord.total_amount - paid;

  if bal <= 0 then
    msg := cust.name || ' (' || cust.phone || ') paid KES ' || new.amount || '. Fully paid.';
  else
    msg := cust.name || ' (' || cust.phone || ') paid KES ' || new.amount || '. Balance: KES ' || bal || '.';
  end if;

  perform notify_staff('payment_received', msg, new.order_id, new.recorded_by);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_payment_insert after insert on payments
for each row execute function trg_payment_received();


-- Daily reminder — called once per page load from the client (see js/dashboard.js).
-- Only actually does anything the first time it's called each day.
create or replace function run_daily_reminder() returns void as $$
declare
  today date := current_date;
  last_date date;
  cnt int; c_overdue int; c_due_today int; c_due_week int; c_unpaid int; c_partial int;
  msg text;
begin
  select last_daily_reminder_date into last_date from system_settings limit 1;
  if last_date = today then
    return;
  end if;

  select count(*) into cnt from orders where status <> 'completed';
  select count(*) into c_overdue from orders where status <> 'completed' and due_date < today;
  select count(*) into c_due_today from orders where status <> 'completed' and due_date = today;
  select count(*) into c_due_week from orders where status <> 'completed' and due_date > today and due_date <= today + 7;

  select count(*) into c_unpaid from orders o
    where o.status <> 'completed'
      and (select coalesce(sum(amount),0) from payments where order_id = o.id) = 0;

  select count(*) into c_partial from orders o
    where o.status <> 'completed'
      and (select coalesce(sum(amount),0) from payments where order_id = o.id) > 0
      and (select coalesce(sum(amount),0) from payments where order_id = o.id) < o.total_amount;

  if cnt > 0 then
    msg := 'Daily summary: ' || cnt || ' unfinished job(s) — ' || c_overdue || ' overdue, ' ||
           c_due_today || ' due today, ' || c_due_week || ' due this week. Payments: ' ||
           c_unpaid || ' unpaid, ' || c_partial || ' partial.';
    perform notify_staff('daily_reminder', msg, null, null);
  end if;

  update system_settings set last_daily_reminder_date = today;
end;
$$ language plpgsql security definer;


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table staff enable row level security;
alter table customers enable row level security;
alter table orders enable row level security;
alter table payments enable row level security;
alter table notification_settings enable row level security;
alter table notifications enable row level security;
alter table system_settings enable row level security;

-- staff: everyone can see the staff list (needed for "handled by" names); only admin manages it
create policy "staff_select" on staff for select using (auth.uid() = id or is_admin());
create policy "staff_insert" on staff for insert with check (is_admin());
create policy "staff_update" on staff for update using (is_admin());

-- customers: any logged-in staff can view; only admin can create/edit
create policy "customers_select" on customers for select using (auth.role() = 'authenticated');
create policy "customers_insert" on customers for insert with check (is_admin());
create policy "customers_update" on customers for update using (is_admin());

-- orders: any logged-in staff can view; only admin can create/edit
create policy "orders_select" on orders for select using (auth.role() = 'authenticated');
create policy "orders_insert" on orders for insert with check (is_admin());
create policy "orders_update" on orders for update using (is_admin());

-- payments: any logged-in staff can view; only admin can record
create policy "payments_select" on payments for select using (auth.role() = 'authenticated');
create policy "payments_insert" on payments for insert with check (is_admin());

-- notification_settings: only admin manages / views
create policy "notification_settings_select" on notification_settings for select using (is_admin());
create policy "notification_settings_insert" on notification_settings for insert with check (is_admin());
create policy "notification_settings_update" on notification_settings for update using (is_admin());

-- notifications: each staff member only sees / marks-read their own
create policy "notifications_select" on notifications for select using (auth.uid() = staff_id);
create policy "notifications_update" on notifications for update using (auth.uid() = staff_id);

-- system_settings: everyone can view (for branding); only admin can update
create policy "system_settings_select" on system_settings for select using (auth.role() = 'authenticated');
create policy "system_settings_update" on system_settings for update using (is_admin());

-- enable realtime on notifications so the bell updates instantly
alter publication supabase_realtime add table notifications;
