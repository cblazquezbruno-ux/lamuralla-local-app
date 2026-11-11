-- custom_client_pricing
alter table public.profiles
  add column if not exists iva_pct numeric,
  add column if not exists custom_pack jsonb,
  add column if not exists extra_day_price numeric;
comment on column public.profiles.iva_pct is 'IVA propio del cliente: null = el general de Ajustes, 0 = sin IVA';
comment on column public.profiles.custom_pack is 'Paquete a medida: {name, features[]}';

create or replace function public.protect_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role; new.username := old.username; new.pack := old.pack; new.price := old.price;
    new.promo := old.promo; new.status := old.status; new.start_date := old.start_date; new.scripts := old.scripts;
    new.mins := old.mins; new.paypal_subscription_id := old.paypal_subscription_id; new.is_demo := old.is_demo;
    new.end_date := old.end_date; new.iva_pct := old.iva_pct; new.custom_pack := old.custom_pack; new.extra_day_price := old.extra_day_price;
    if old.cancel_requested_at is not null then new.cancel_requested_at := old.cancel_requested_at; end if;
  end if;
  return new;
end $$;

create or replace function public.set_extra_days(p_month text, p_delta int) returns int language plpgsql security definer set search_path = public as $$
declare e record; s jsonb; n int; newd int; dp numeric;
begin
  if auth.uid() is null then raise exception 'No has iniciado sesión'; end if;
  select data into s from public.settings where id = 1;
  select coalesce(extra_day_price, (s->>'extraDay')::numeric, 120) into dp from public.profiles where id = auth.uid();
  insert into public.extras(client_id, month, days, paid_days, day_price) values (auth.uid(), p_month, 0, 0, dp)
    on conflict (client_id, month) do nothing;
  select * into e from public.extras where client_id = auth.uid() and month = p_month;
  newd := greatest(0, e.days + p_delta);
  if newd > 4 then raise exception 'Máximo 4 días extra al mes. Escríbenos por el chat si necesitas más.'; end if;
  if newd < e.paid_days then raise exception 'Ese día ya está pagado'; end if;
  select count(*) into n from public.bookings where client_id = auth.uid() and to_char(date,'YYYY-MM') = p_month;
  if newd + 1 < n then raise exception 'Primero cancela uno de tus días reservados'; end if;
  update public.extras set days = newd, day_price = case when e.paid_days = 0 then dp else day_price end
    where client_id = auth.uid() and month = p_month;
  return newd;
end $$;
