-- ============================================================
-- SCHEMA ADDITIONS — run this AFTER schema.sql
-- ============================================================

-- ---------- Task assignment: who actually does the work ----------
alter table orders add column assigned_to uuid references staff(id);
-- handled_by = who logged the order (usually admin)
-- assigned_to = the worker doing the sewing/tailoring

-- ---------- Settings additions ----------
alter table system_settings add column workers_can_view_payments boolean not null default false;
alter table system_settings add column workers_can_view_financials boolean not null default false;
alter table system_settings add column daily_reminder_time time not null default '18:00';
alter table system_settings add column financial_report_frequency text not null default 'daily'
  check (financial_report_frequency in ('daily','monthly','yearly'));
alter table system_settings add column financial_report_time time not null default '19:00';

-- ---------- Financials ----------
create table expenses (
  id bigint generated always as identity primary key,
  description text not null,
  amount numeric not null,
  expense_date date not null default current_date,
  recorded_by uuid not null references staff(id),
  created_at timestamptz not null default now()
);

create table salary_payments (
  id bigint generated always as identity primary key,
  staff_id uuid not null references staff(id),
  amount numeric not null,
  pay_date date not null default current_date,
  recorded_by uuid not null references staff(id),
  created_at timestamptz not null default now()
);

alter table expenses enable row level security;
alter table salary_payments enable row level security;

create policy "expenses_select" on expenses for select using (
  is_admin() or (select workers_can_view_financials from system_settings limit 1)
);
create policy "expenses_insert" on expenses for insert with check (is_admin());

create policy "salary_select" on salary_payments for select using (
  is_admin() or (select workers_can_view_financials from system_settings limit 1)
);
create policy "salary_insert" on salary_payments for insert with check (is_admin());


-- ---------- Replace payments_select: gate behind the permission flag ----------
drop policy if exists "payments_select" on payments;
create policy "payments_select" on payments for select using (
  is_admin() or (select workers_can_view_payments from system_settings limit 1)
);


-- ---------- Financial report function (income vs expenses vs salaries) ----------
create or replace function get_financial_report(period text, ref_date date default current_date)
returns table(total_income numeric, total_expenses numeric, total_salaries numeric, net numeric) as $$
declare
  start_d date;
  end_d date;
begin
  if period = 'daily' then
    start_d := ref_date; end_d := ref_date;
  elsif period = 'monthly' then
    start_d := date_trunc('month', ref_date)::date;
    end_d := (date_trunc('month', ref_date) + interval '1 month' - interval '1 day')::date;
  elsif period = 'yearly' then
    start_d := date_trunc('year', ref_date)::date;
    end_d := (date_trunc('year', ref_date) + interval '1 year' - interval '1 day')::date;
  else
    raise exception 'invalid period';
  end if;

  return query
  select
    coalesce((select sum(amount) from payments where created_at::date between start_d and end_d), 0),
    coalesce((select sum(amount) from expenses where expense_date between start_d and end_d), 0),
    coalesce((select sum(amount) from salary_payments where pay_date between start_d and end_d), 0),
    coalesce((select sum(amount) from payments where created_at::date between start_d and end_d), 0)
      - coalesce((select sum(amount) from expenses where expense_date between start_d and end_d), 0)
      - coalesce((select sum(amount) from salary_payments where pay_date between start_d and end_d), 0);
end;
$$ language plpgsql security definer stable;

-- workers can call this only if permitted; admin always can
create or replace function get_financial_report_guarded(period text, ref_date date default current_date)
returns table(total_income numeric, total_expenses numeric, total_salaries numeric, net numeric) as $$
begin
  if not (is_admin() or (select workers_can_view_financials from system_settings limit 1)) then
    raise exception 'not permitted';
  end if;
  return query select * from get_financial_report(period, ref_date);
end;
$$ language plpgsql security definer stable;


-- ---------- Updated new_order notification: include assigned worker + dates ----------
create or replace function trg_new_order() returns trigger as $$
declare
  cust record;
  assignee record;
begin
  select name, phone into cust from customers where id = new.customer_id;
  select name, phone into assignee from staff where id = new.assigned_to;

  perform notify_staff('new_order',
    'New task: ' || new.garment_type || ' for ' || cust.name || ' (' || cust.phone || '). ' ||
    'Assigned to ' || assignee.name || ' (' || assignee.phone || '). ' ||
    'Assigned: ' || new.date_received || '. Completion due: ' || coalesce(new.due_date::text, 'not set') || '.',
    new.id, new.handled_by);
  return new;
end;
$$ language plpgsql security definer;


-- ---------- Scheduled notifications at admin-chosen times (requires pg_cron) ----------
-- In Supabase Dashboard: Database → Extensions → enable "pg_cron" (free, one click).
-- Then run the block below ONCE. It reschedules itself whenever admin changes the time
-- in system_settings, via the reschedule_reports() function/trigger at the bottom.

create extension if not exists pg_cron;

create or replace function cron_daily_reminder_job() returns void as $$
begin
  perform run_daily_reminder();
end;
$$ language plpgsql security definer;

create or replace function cron_financial_report_job() returns void as $$
declare
  freq text;
  rpt record;
  msg text;
begin
  select financial_report_frequency into freq from system_settings limit 1;
  select * into rpt from get_financial_report(freq);
  msg := upper(freq) || ' financial report — Income: KES ' || rpt.total_income ||
         ', Expenses: KES ' || rpt.total_expenses || ', Salaries: KES ' || rpt.total_salaries ||
         ', Net: KES ' || rpt.net || ' (' || (case when rpt.net >= 0 then 'profit' else 'loss' end) || ').';
  insert into notifications (staff_id, event_type, message)
  select id, 'financial_report', msg from staff where role = 'admin' and active = true;
end;
$$ language plpgsql security definer;

-- (re)schedule both cron jobs based on current system_settings times
create or replace function reschedule_reports() returns void as $$
declare
  s record;
begin
  select * into s from system_settings limit 1;

  if exists (select 1 from cron.job where jobname = 'daily-work-reminder') then
    perform cron.unschedule('daily-work-reminder');
  end if;
  if exists (select 1 from cron.job where jobname = 'financial-report') then
    perform cron.unschedule('financial-report');
  end if;

  perform cron.schedule('daily-work-reminder',
    extract(minute from s.daily_reminder_time)::text || ' ' || extract(hour from s.daily_reminder_time)::text || ' * * *',
    'select cron_daily_reminder_job();');

  perform cron.schedule('financial-report',
    extract(minute from s.financial_report_time)::text || ' ' || extract(hour from s.financial_report_time)::text || ' * * *',
    'select cron_financial_report_job();');
end;
$$ language plpgsql security definer;

-- run once to schedule with the defaults
select reschedule_reports();

-- and automatically reschedule whenever admin updates the times
create or replace function trg_settings_changed() returns trigger as $$
begin
  if new.daily_reminder_time is distinct from old.daily_reminder_time
     or new.financial_report_time is distinct from old.financial_report_time
     or new.financial_report_frequency is distinct from old.financial_report_frequency then
    perform reschedule_reports();
  end if;
  return new;
end;
$$ language plpgsql security definer;

create trigger on_settings_changed after update on system_settings
for each row execute function trg_settings_changed();
