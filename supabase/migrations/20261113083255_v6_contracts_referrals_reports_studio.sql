-- ===== perfil =====
alter table public.profiles add column if not exists referral_code text unique,
  add column if not exists referred_by uuid references public.profiles(id) on delete set null,
  add column if not exists contract_signed_at timestamptz;

create or replace function public.protect_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.bypass', true), '') = 'on' then return new; end if;
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role; new.username := old.username; new.pack := old.pack; new.price := old.price;
    new.promo := old.promo; new.status := old.status; new.start_date := old.start_date; new.scripts := old.scripts;
    new.mins := old.mins; new.paypal_subscription_id := old.paypal_subscription_id; new.is_demo := old.is_demo;
    new.end_date := old.end_date; new.iva_pct := old.iva_pct; new.custom_pack := old.custom_pack; new.extra_day_price := old.extra_day_price;
    new.meeting_status := old.meeting_status; new.meeting_at := old.meeting_at; new.upgrade := old.upgrade;
    new.referral_code := old.referral_code; new.referred_by := old.referred_by; new.contract_signed_at := old.contract_signed_at;
    if old.cancel_requested_at is not null then new.cancel_requested_at := old.cancel_requested_at; end if;
  end if;
  return new;
end $$;

create or replace function private.make_ref_code(p_business text) returns text language plpgsql as $$
declare base text := upper(left(regexp_replace(translate(coalesce(p_business,'LOCAL'),'áéíóúÁÉÍÓÚñÑüÜ','aeiouAEIOUnNuU'),'[^A-Za-z0-9]','','g'),8)); c text;
begin
  if base = '' then base := 'LOCAL'; end if;
  loop c := base || '-' || upper(substr(md5(random()::text), 1, 3)); exit when not exists (select 1 from public.profiles where referral_code = c); end loop;
  return c;
end $$;
create or replace function private.set_ref_code() returns trigger language plpgsql security definer set search_path = public, private as $$
begin
  if new.role = 'client' and new.referral_code is null then new.referral_code := private.make_ref_code(new.business); end if;
  return new;
end $$;
create trigger trg_ref_code before insert on public.profiles for each row execute function private.set_ref_code();
select set_config('app.bypass','on',true);
update public.profiles set referral_code = private.make_ref_code(business) where role = 'client' and referral_code is null;
select set_config('app.bypass','off',true);

-- ===== contratos firmados =====
create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  version text, name text not null, nif text, text text not null, text_hash text,
  signature_path text not null, pdf_path text, user_agent text,
  signed_at timestamptz not null default now()
);
create index on public.contracts(client_id);
alter table public.contracts enable row level security;
create policy contracts_sel on public.contracts for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy contracts_upd on public.contracts for update to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function private.render_contract(p public.profiles, p_name text, p_nif text) returns text language plpgsql stable security definer set search_path = public as $$
declare s jsonb; t text; pk jsonb; iv numeric; inv jsonb;
begin
  select data into s from public.settings where id = 1;
  inv := coalesce(s->'invoice','{}'::jsonb);
  select x into pk from jsonb_array_elements(s->'packs') x where x->>'id' = p.pack limit 1;
  iv := coalesce(p.iva_pct, (s->>'iva')::numeric);
  t := coalesce(s->>'contract', '');
  t := replace(t, '{fecha}', to_char(now() at time zone 'Europe/Madrid', 'DD/MM/YYYY'));
  t := replace(t, '{empresa}', coalesce(nullif(inv->>'name',''), 'La Muralla Project'));
  t := replace(t, '{nif_empresa}', coalesce(nullif(inv->>'nif',''), '—'));
  t := replace(t, '{direccion_empresa}', trim(both ' ,' from coalesce(inv->>'address','') || ', ' || coalesce(inv->>'city','')));
  t := replace(t, '{email_empresa}', coalesce(inv->>'email',''));
  t := replace(t, '{negocio}', coalesce(p.business,''));
  t := replace(t, '{firmante}', coalesce(p_name,''));
  t := replace(t, '{nif_cliente}', coalesce(nullif(p_nif,''), '—'));
  t := replace(t, '{pack}', coalesce(p.custom_pack->>'name', pk->>'name', p.pack));
  t := replace(t, '{precio}', to_char(coalesce(p.price,0), 'FM999990.00') || ' €');
  t := replace(t, '{iva}', case when iv = 0 then 'sin IVA' else '+ IVA (' || iv || ' %)' end);
  t := replace(t, '{permanencia}', coalesce(s->>'minMonths','3'));
  t := replace(t, '{aviso}', coalesce(s->>'noticeDays','15'));
  t := replace(t, '{dia_extra}', to_char(coalesce(p.extra_day_price, (s->>'extraDay')::numeric, 120), 'FM999990.00') || ' €');
  t := replace(t, '{horas_eventos}', coalesce(s->>'eventHours','24'));
  return t;
end $$;

create or replace function public.contract_preview(p_name text, p_nif text) returns text language plpgsql stable security definer set search_path = public, private as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found then raise exception 'No permitido'; end if;
  return private.render_contract(p, p_name, p_nif);
end $$;

create or replace function public.sign_contract(p_name text, p_nif text, p_sig_path text, p_ua text) returns uuid language plpgsql security definer set search_path = public, private, extensions as $$
declare p public.profiles; t text; cid uuid; bill jsonb;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found or p.role <> 'client' then raise exception 'No permitido'; end if;
  if length(trim(coalesce(p_name,''))) < 3 then raise exception 'Escribe tu nombre completo'; end if;
  if p_sig_path is null or split_part(p_sig_path, '/', 1) <> p.id::text then raise exception 'Firma no válida'; end if;
  t := private.render_contract(p, trim(p_name), upper(trim(coalesce(p_nif,''))));
  insert into public.contracts(client_id, version, name, nif, text, text_hash, signature_path, user_agent)
  values (p.id, coalesce((select data->>'contractVersion' from public.settings where id=1),'1'), trim(p_name), upper(trim(coalesce(p_nif,''))), t,
          encode(digest(t, 'sha256'), 'hex'), p_sig_path, left(p_ua, 300)) returning id into cid;
  bill := coalesce(p.billing, '{}'::jsonb);
  if coalesce(bill->>'nif','') = '' and coalesce(p_nif,'') <> '' then bill := bill || jsonb_build_object('nif', upper(trim(p_nif))); end if;
  perform set_config('app.bypass', 'on', true);
  update public.profiles set contract_signed_at = now(), billing = bill where id = p.id;
  perform set_config('app.bypass', 'off', true);
  insert into public.messages(client_id, sender_id, from_team, who, text)
  values (p.id, p.id, false, coalesce(p.contact,'Cliente'), 'He firmado el contrato desde la app ✍️');
  return cid;
end $$;

create or replace function private.contract_pdf() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare s text; u text;
begin
  select value into u from private.config where key = 'notify_url';
  select value into s from private.config where key = 'notify_secret';
  if u is not null then
    perform net.http_post(url := replace(u, '/notify', '/contract'), body := jsonb_build_object('contract_id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', s));
  end if;
  return new;
end $$;
create trigger trg_contract_pdf after insert on public.contracts for each row execute function private.contract_pdf();

-- ===== invita a otro local + ruleta =====
create table public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer uuid not null references public.profiles(id) on delete cascade,
  referred uuid unique references public.profiles(id) on delete set null,
  referred_name text,
  status text not null default 'pendiente' check (status in ('pendiente','activada','girada','entregada')),
  prize text, spun_at timestamptz, delivered_at timestamptz, created_at timestamptz default now()
);
create index on public.referrals(referrer);
alter table public.referrals enable row level security;
create policy ref_sel on public.referrals for select to authenticated using (referrer = (select auth.uid()) or public.is_admin());
create policy ref_upd on public.referrals for update to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function private.referral_on_payment() returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.status = 'pagado' and (tg_op = 'INSERT' or coalesce(old.status,'') <> 'pagado') then
    for r in update public.referrals set status = 'activada' where referred = new.client_id and status = 'pendiente' returning * loop
      insert into public.messages(client_id, sender_id, from_team, who, text)
      values (r.referrer, r.referrer, true, 'La Muralla', '🎡 ¡' || coalesce(r.referred_name,'El local que invitaste') || ' ya es de La Muralla! Tienes una tirada en la Ruleta de La Muralla: entra en Perfil › Invita a otro local.');
    end loop;
  end if;
  return new;
end $$;
create trigger trg_referral_on_payment after insert or update of status on public.payments for each row execute function private.referral_on_payment();

create or replace function public.spin_wheel(p_ref uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; prizes jsonb; total numeric := 0; pick numeric; acc numeric := 0; i int := 0; chosen int := 0; lbl text; p record;
begin
  select * into r from public.referrals where id = p_ref and referrer = auth.uid() for update;
  if not found then raise exception 'No encontrada'; end if;
  if r.status <> 'activada' then raise exception 'Esta tirada no está disponible'; end if;
  select coalesce(data->'wheel', '[]'::jsonb) into prizes from public.settings where id = 1;
  if jsonb_array_length(prizes) = 0 then raise exception 'La ruleta no está configurada'; end if;
  select sum(coalesce((x->>'weight')::numeric, 1)) into total from jsonb_array_elements(prizes) x;
  pick := random() * total;
  for i in 0 .. jsonb_array_length(prizes) - 1 loop
    acc := acc + coalesce((prizes->i->>'weight')::numeric, 1);
    if pick < acc then chosen := i; exit; end if;
  end loop;
  lbl := prizes->chosen->>'label';
  update public.referrals set status = 'girada', prize = lbl, spun_at = now() where id = r.id;
  select * into p from public.profiles where id = auth.uid();
  insert into public.messages(client_id, sender_id, from_team, who, text)
  values (p.id, p.id, false, coalesce(p.contact,'Cliente'), '🎡 Me ha tocado en la Ruleta de La Muralla: ' || lbl);
  return jsonb_build_object('index', chosen, 'label', lbl);
end $$;

-- ===== resultados del mes =====
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  month text not null, data jsonb not null default '{}'::jsonb, best text, note text,
  created_by uuid, created_at timestamptz default now(), unique (client_id, month)
);
alter table public.reports enable row level security;
create policy rep_sel on public.reports for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy rep_all on public.reports for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ===== Haz tu propio podcast =====
create table public.studio_requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  data jsonb not null, status text not null default 'nueva' check (status in ('nueva','contactada','cerrada','descartada')),
  created_at timestamptz default now()
);
alter table public.studio_requests enable row level security;
create policy sr_sel on public.studio_requests for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy sr_ins on public.studio_requests for insert to authenticated with check (client_id = (select auth.uid()) and status = 'nueva');
create policy sr_upd on public.studio_requests for update to authenticated using (public.is_admin()) with check (public.is_admin());
create or replace function private.studio_msg() returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from public.profiles where id = new.client_id;
  insert into public.messages(client_id, sender_id, from_team, who, text)
  values (new.client_id, new.client_id, false, coalesce(p.contact,'Cliente'), '🎙️ Quiero hacer mi propio podcast: «' || coalesce(new.data->>'nombre','sin nombre') || '». Os lo he enviado desde la app.');
  return new;
end $$;
create trigger trg_studio_msg after insert on public.studio_requests for each row execute function private.studio_msg();

-- ===== recuperar contraseña =====
create table if not exists private.recovery (user_id uuid primary key, code_hash text not null, expires_at timestamptz not null, tries int not null default 0);

-- ===== recordatorios 24 h antes =====
create or replace function private.daily_reminders() returns void language plpgsql security definer set search_path = public as $$
declare r record; tm date := ((now() at time zone 'Europe/Madrid')::date + 1); tid uuid;
begin
  select id into tid from public.profiles where role = 'admin' order by created_at limit 1;
  for r in select b.*, p.contact from public.bookings b join public.profiles p on p.id = b.client_id where b.date = tm loop
    insert into public.messages(client_id, sender_id, from_team, who, text) values (r.client_id, coalesce(tid, r.client_id), true, 'La Muralla',
      '⏰ Recordatorio: mañana grabamos (' || r.slot || ').' || case when r.needs_sent then ' Repasa en Inicio la lista de lo que necesitamos y márcala.' else '' end);
  end loop;
  for r in select * from public.profiles where role = 'client' and meeting_status = 'confirmada' and (meeting_at at time zone 'Europe/Madrid')::date = tm loop
    insert into public.messages(client_id, sender_id, from_team, who, text) values (r.id, coalesce(tid, r.id), true, 'La Muralla',
      '⏰ Recordatorio: mañana a las ' || to_char(r.meeting_at at time zone 'Europe/Madrid', 'HH24:MI') || ' tenemos la reunión de arranque.');
  end loop;
  for r in select * from public.profiles where role = 'client' and upgrade->>'status' = 'confirmada' and ((upgrade->>'at')::timestamptz at time zone 'Europe/Madrid')::date = tm loop
    insert into public.messages(client_id, sender_id, from_team, who, text) values (r.id, coalesce(tid, r.id), true, 'La Muralla',
      '⏰ Recordatorio: mañana a las ' || to_char((r.upgrade->>'at')::timestamptz at time zone 'Europe/Madrid', 'HH24:MI') || ' hablamos del Pack Completo.');
  end loop;
end $$;
select cron.schedule('recordatorios-24h', '0 9 * * *', 'select private.daily_reminders()');

-- ===== permisos y tiempo real =====
revoke execute on function public.contract_preview(text, text) from public, anon;
revoke execute on function public.sign_contract(text, text, text, text) from public, anon;
revoke execute on function public.spin_wheel(uuid) from public, anon;
grant execute on function public.contract_preview(text, text) to authenticated;
grant execute on function public.sign_contract(text, text, text, text) to authenticated;
grant execute on function public.spin_wheel(uuid) to authenticated;
alter publication supabase_realtime add table public.contracts, public.referrals, public.reports, public.studio_requests;
