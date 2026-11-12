alter table public.profiles add column if not exists upgrade jsonb;
create or replace function public.protect_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.bypass', true), '') = 'on' then return new; end if;
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role; new.username := old.username; new.pack := old.pack; new.price := old.price;
    new.promo := old.promo; new.status := old.status; new.start_date := old.start_date; new.scripts := old.scripts;
    new.mins := old.mins; new.paypal_subscription_id := old.paypal_subscription_id; new.is_demo := old.is_demo;
    new.end_date := old.end_date; new.iva_pct := old.iva_pct; new.custom_pack := old.custom_pack; new.extra_day_price := old.extra_day_price;
    new.meeting_status := old.meeting_status; new.meeting_at := old.meeting_at; new.upgrade := old.upgrade;
    if old.cancel_requested_at is not null then new.cancel_requested_at := old.cancel_requested_at; end if;
  end if;
  return new;
end $$;
create or replace function public.request_upgrade(p_pref jsonb) returns void language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found or p.role <> 'client' then raise exception 'No permitido'; end if;
  if p.pack = 'completo' then raise exception 'Ya tienes el Pack Completo'; end if;
  perform set_config('app.bypass', 'on', true);
  update public.profiles set upgrade = jsonb_build_object('status','solicitada','pack','completo','pref',p_pref,'requested_at',now()) where id = p.id;
  perform set_config('app.bypass', 'off', true);
  insert into public.messages(client_id, sender_id, from_team, who, text)
  values (p.id, p.id, false, coalesce(p.contact,'Cliente'),
    'Quiero pasarme al Pack Completo. ¿Nos reunimos para verlo? Me viene bien: ' || coalesce(p_pref->>'fecha','cuando digáis') || ' · ' || coalesce(p_pref->>'franja','') || ' · ' || coalesce(p_pref->>'modo',''));
end $$;
revoke execute on function public.request_upgrade(jsonb) from public, anon;
grant execute on function public.request_upgrade(jsonb) to authenticated;
