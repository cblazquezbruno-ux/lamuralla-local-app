-- rls_and_functions
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin') $$;
create or replace function public.today_es() returns date language sql stable set search_path = public as
$$ select (now() at time zone 'Europe/Madrid')::date $$;

alter table public.profiles enable row level security;
alter table public.settings enable row level security;
alter table public.availability enable row level security;
alter table public.bookings enable row level security;
alter table public.extras enable row level security;
alter table public.events enable row level security;
alter table public.payments enable row level security;
alter table public.messages enable row level security;

create policy profiles_sel on public.profiles for select to authenticated using (id = (select auth.uid()) or public.is_admin());
create policy profiles_upd on public.profiles for update to authenticated using (id = (select auth.uid()) or public.is_admin()) with check (id = (select auth.uid()) or public.is_admin());
create policy profiles_del on public.profiles for delete to authenticated using (public.is_admin());

create policy settings_sel on public.settings for select to anon, authenticated using (true);
create policy settings_upd on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy avail_sel on public.availability for select to authenticated using (true);
create policy avail_ins on public.availability for insert to authenticated with check (public.is_admin());
create policy avail_upd on public.availability for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy avail_del on public.availability for delete to authenticated using (public.is_admin());

create policy book_sel on public.bookings for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy book_upd on public.bookings for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy book_del on public.bookings for delete to authenticated using (public.is_admin());

create policy extras_sel on public.extras for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy extras_upd on public.extras for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy ev_sel on public.events for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy ev_ins on public.events for insert to authenticated with check (client_id = (select auth.uid()) and status = 'pendiente' and quote is null and coalesce(paid,false) = false);
create policy ev_upd on public.events for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy pay_sel on public.payments for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy pay_ins on public.payments for insert to authenticated with check (public.is_admin());

create policy msg_sel on public.messages for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy msg_ins on public.messages for insert to authenticated with check (
  (client_id = (select auth.uid()) and from_team = false and sender_id = (select auth.uid()))
  or (public.is_admin() and from_team = true and sender_id = (select auth.uid()))
);

create or replace function public.protect_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role; new.username := old.username; new.pack := old.pack; new.price := old.price;
    new.promo := old.promo; new.status := old.status; new.start_date := old.start_date; new.scripts := old.scripts;
    new.mins := old.mins; new.paypal_subscription_id := old.paypal_subscription_id; new.is_demo := old.is_demo;
  end if;
  return new;
end $$;
create trigger trg_protect_profile before update on public.profiles for each row execute function public.protect_profile();

create or replace function public.taken_slots() returns table(date date, slot text) language sql stable security definer set search_path = public as
$$ select b.date, b.slot from public.bookings b where b.date >= public.today_es() $$;

create or replace function public.book_slot(p_date date, p_slot text, p_replace date default null) returns void language plpgsql security definer set search_path = public as $$
declare s jsonb; lead_days int; m text; n int; allowed int; b record;
begin
  if auth.uid() is null then raise exception 'No has iniciado sesión'; end if;
  select data into s from public.settings where id = 1;
  lead_days := ceil(coalesce((s->>'changeHours')::numeric, 48) / 24);
  if p_date < public.today_es() + lead_days then raise exception 'Ese día ya no se puede reservar (menos de % h)', coalesce(s->>'changeHours','48'); end if;
  if not exists (select 1 from public.availability a where a.date = p_date and p_slot = any(a.slots)) then raise exception 'Ese día u horario ya no está disponible'; end if;
  if exists (select 1 from public.bookings x where x.date = p_date and x.slot = p_slot) then raise exception 'Esa franja ya está cogida'; end if;
  if p_replace is not null then
    select * into b from public.bookings where client_id = auth.uid() and date = p_replace limit 1;
    if not found then raise exception 'No encuentro tu reserva'; end if;
    if p_replace < public.today_es() + lead_days then raise exception 'Ya no se puede cambiar: quedan menos de % h', coalesce(s->>'changeHours','48'); end if;
    update public.bookings set date = p_date, slot = p_slot where id = b.id;
    update public.profiles set checks = '{}'::jsonb where id = auth.uid();
    return;
  end if;
  m := to_char(p_date, 'YYYY-MM');
  select count(*) into n from public.bookings where client_id = auth.uid() and to_char(date,'YYYY-MM') = m;
  allowed := 1 + coalesce((select days from public.extras where client_id = auth.uid() and month = m), 0);
  if n >= allowed then raise exception 'Ya tienes tus días de este mes. Añade un día extra para reservar otro.'; end if;
  insert into public.bookings(client_id, date, slot) values (auth.uid(), p_date, p_slot);
end $$;

create or replace function public.set_extra_days(p_month text, p_delta int) returns int language plpgsql security definer set search_path = public as $$
declare e record; s jsonb; n int; newd int;
begin
  if auth.uid() is null then raise exception 'No has iniciado sesión'; end if;
  select data into s from public.settings where id = 1;
  insert into public.extras(client_id, month, days, paid_days, day_price) values (auth.uid(), p_month, 0, 0, coalesce((s->>'extraDay')::numeric,120))
    on conflict (client_id, month) do nothing;
  select * into e from public.extras where client_id = auth.uid() and month = p_month;
  newd := greatest(0, e.days + p_delta);
  if newd > 4 then raise exception 'Máximo 4 días extra al mes. Escríbenos por el chat si necesitas más.'; end if;
  if newd < e.paid_days then raise exception 'Ese día ya está pagado'; end if;
  select count(*) into n from public.bookings where client_id = auth.uid() and to_char(date,'YYYY-MM') = p_month;
  if newd + 1 < n then raise exception 'Primero cancela uno de tus días reservados'; end if;
  update public.extras set days = newd, day_price = case when e.paid_days = 0 then coalesce((s->>'extraDay')::numeric,120) else day_price end
    where client_id = auth.uid() and month = p_month;
  return newd;
end $$;

create or replace function public.respond_event(p_id uuid, p_accept boolean) returns void language plpgsql security definer set search_path = public as $$
declare e record;
begin
  select * into e from public.events where id = p_id and client_id = auth.uid();
  if not found or e.status <> 'presupuesto' then raise exception 'Este presupuesto ya no está disponible'; end if;
  if p_accept then
    update public.events set status = 'aceptado', month = to_char(coalesce(e.date, public.today_es()), 'YYYY-MM') where id = p_id;
  else
    update public.events set status = 'descartado' where id = p_id;
  end if;
end $$;

create or replace function public.mark_read(p_client uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then update public.messages set read_by_team = true where client_id = p_client and from_team = false and not read_by_team;
  elsif auth.uid() = p_client then update public.messages set read_by_client = true where client_id = p_client and from_team = true and not read_by_client;
  end if;
end $$;

alter publication supabase_realtime add table public.messages, public.events, public.bookings, public.availability, public.extras, public.payments, public.profiles, public.settings;
