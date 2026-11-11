-- ===== reunión de arranque, logo y datos de facturación =====
alter table public.profiles
  add column if not exists meeting_status text not null default 'pendiente',
  add column if not exists meeting_at timestamptz,
  add column if not exists meeting_pref jsonb,
  add column if not exists logo_path text,
  add column if not exists billing jsonb default '{}'::jsonb;
alter table public.profiles add constraint profiles_meeting_status_chk check (meeting_status in ('pendiente','solicitada','confirmada','hecha'));

create or replace function public.protect_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.bypass', true), '') = 'on' then return new; end if;
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role; new.username := old.username; new.pack := old.pack; new.price := old.price;
    new.promo := old.promo; new.status := old.status; new.start_date := old.start_date; new.scripts := old.scripts;
    new.mins := old.mins; new.paypal_subscription_id := old.paypal_subscription_id; new.is_demo := old.is_demo;
    new.end_date := old.end_date; new.iva_pct := old.iva_pct; new.custom_pack := old.custom_pack; new.extra_day_price := old.extra_day_price;
    new.meeting_status := old.meeting_status; new.meeting_at := old.meeting_at;
    if old.cancel_requested_at is not null then new.cancel_requested_at := old.cancel_requested_at; end if;
  end if;
  return new;
end $$;

create or replace function public.request_meeting(p_pref jsonb) returns void language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found or p.role <> 'client' then raise exception 'No permitido'; end if;
  if p.meeting_status = 'hecha' then raise exception 'La reunión ya está hecha'; end if;
  perform set_config('app.bypass', 'on', true);
  update public.profiles set meeting_status = 'solicitada', meeting_pref = p_pref where id = p.id;
  perform set_config('app.bypass', 'off', true);
  insert into public.messages(client_id, sender_id, from_team, who, text)
  values (p.id, p.id, false, coalesce(p.contact, 'Cliente'),
    'He solicitado la reunión de arranque: ' || coalesce(p_pref->>'fecha', 'sin fecha') || ' · ' || coalesce(p_pref->>'franja', '') || ' · ' || coalesce(p_pref->>'modo', '') || coalesce(' · ' || nullif(p_pref->>'nota', ''), ''));
end $$;

-- ===== qué necesitamos: por rodaje, lo envía el equipo =====
alter table public.bookings
  add column if not exists needs jsonb default '[]'::jsonb,
  add column if not exists needs_sent boolean default false,
  add column if not exists checks jsonb default '{}'::jsonb,
  add column if not exists note text;

create or replace function public.tick_need(p_booking uuid, p_idx int) returns jsonb language plpgsql security definer set search_path = public as $$
declare b record; c jsonb;
begin
  select * into b from public.bookings where id = p_booking and client_id = auth.uid();
  if not found then raise exception 'No encontrado'; end if;
  c := coalesce(b.checks, '{}'::jsonb);
  if coalesce((c->>p_idx::text)::boolean, false) then c := c - p_idx::text; else c := c || jsonb_build_object(p_idx::text, true); end if;
  update public.bookings set checks = c where id = b.id;
  return c;
end $$;

create or replace function public.book_slot(p_date date, p_slot text, p_replace date default null) returns void language plpgsql security definer set search_path = public as $$
declare s jsonb; lead_days int; m text; n int; allowed int; b record; ms text;
begin
  if auth.uid() is null then raise exception 'No has iniciado sesión'; end if;
  select meeting_status into ms from public.profiles where id = auth.uid();
  if coalesce(ms, 'pendiente') <> 'hecha' then raise exception 'Primero hacemos la reunión de arranque. Cuando esté hecha podrás elegir tu día de rodaje.'; end if;
  select data into s from public.settings where id = 1;
  lead_days := ceil(coalesce((s->>'changeHours')::numeric, 48) / 24);
  if p_date < public.today_es() + lead_days then raise exception 'Ese día ya no se puede reservar (menos de % h)', coalesce(s->>'changeHours','48'); end if;
  if not exists (select 1 from public.availability a where a.date = p_date and p_slot = any(a.slots)) then raise exception 'Ese día u horario ya no está disponible'; end if;
  if exists (select 1 from public.bookings x where x.date = p_date and x.slot = p_slot) then raise exception 'Esa franja la acaba de coger otro local. Elige otra.'; end if;
  if p_replace is not null then
    select * into b from public.bookings where client_id = auth.uid() and date = p_replace limit 1;
    if not found then raise exception 'No encuentro tu reserva'; end if;
    if p_replace < public.today_es() + lead_days then raise exception 'Ya no se puede cambiar: quedan menos de % h', coalesce(s->>'changeHours','48'); end if;
    update public.bookings set date = p_date, slot = p_slot where id = b.id;
    return;
  end if;
  m := to_char(p_date, 'YYYY-MM');
  select count(*) into n from public.bookings where client_id = auth.uid() and to_char(date,'YYYY-MM') = m;
  allowed := 1 + coalesce((select days from public.extras where client_id = auth.uid() and month = m), 0);
  if n >= allowed then raise exception 'Ya tienes tus días de este mes. Añade un día extra para reservar otro.'; end if;
  insert into public.bookings(client_id, date, slot) values (auth.uid(), p_date, p_slot);
end $$;

-- ===== calendario de publicaciones =====
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  date date not null,
  type text not null default 'reel',
  title text not null,
  description text,
  status text not null default 'planificado',
  files text[] default '{}',
  created_at timestamptz default now()
);
create index on public.posts(client_id, date);
alter table public.posts enable row level security;
create policy posts_sel on public.posts for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy posts_ins on public.posts for insert to authenticated with check (public.is_admin());
create policy posts_upd on public.posts for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy posts_rm on public.posts for delete to authenticated using (public.is_admin());

-- ===== archivos: guiones (equipo) y envíos del cliente =====
create table public.files (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('guion','cliente','contenido','factura')),
  title text,
  body text,
  path text,
  mime text,
  size bigint,
  uploaded_by uuid,
  created_at timestamptz default now()
);
create index on public.files(client_id, kind);
alter table public.files enable row level security;
create policy files_sel on public.files for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy files_ins on public.files for insert to authenticated with check (public.is_admin() or (client_id = (select auth.uid()) and kind = 'cliente' and uploaded_by = (select auth.uid())));
create policy files_upd on public.files for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy files_rm on public.files for delete to authenticated using (public.is_admin() or (client_id = (select auth.uid()) and kind = 'cliente'));

-- ===== tareas del equipo =====
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.profiles(id) on delete cascade,
  assignee uuid references public.profiles(id) on delete set null,
  title text not null,
  due date,
  minutes int,
  done boolean not null default false,
  done_at timestamptz,
  created_by uuid,
  created_at timestamptz default now()
);
create index on public.tasks(assignee, due);
create index on public.tasks(client_id);
alter table public.tasks enable row level security;
create policy tasks_all on public.tasks for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ===== pagos por otros métodos (transferencia, etc.) que confirma el equipo =====
create policy pay_upd on public.payments for update to authenticated using (public.is_admin()) with check (public.is_admin());
create or replace function public.report_payment(p_concept text, p_base numeric, p_method text, p_note text) returns void language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found or p.role <> 'client' then raise exception 'No permitido'; end if;
  if p_base is null or p_base <= 0 then raise exception 'Importe no válido'; end if;
  insert into public.payments(client_id, concept, base, status, method, iva)
  values (p.id, left(coalesce(p_concept, 'Pago'), 120), p_base, 'pendiente', left(coalesce(p_method, 'transferencia'), 30),
          coalesce(p.iva_pct, (select (data->>'iva')::numeric from public.settings where id = 1)));
  insert into public.messages(client_id, sender_id, from_team, who, text)
  values (p.id, p.id, false, coalesce(p.contact, 'Cliente'), 'He pagado por ' || coalesce(p_method, 'transferencia') || ': ' || coalesce(p_concept, '') || coalesce(' · ' || nullif(p_note, ''), '') || '. ¿Me lo confirmáis?');
end $$;

-- ===== facturas =====
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  client_id uuid references public.profiles(id) on delete set null,
  payment_id uuid unique references public.payments(id) on delete set null,
  number text unique not null,
  date date not null default ((now() at time zone 'Europe/Madrid')::date),
  concept text,
  base numeric not null default 0,
  iva_pct numeric not null default 21,
  iva numeric not null default 0,
  total numeric not null default 0,
  client_data jsonb,
  issuer jsonb,
  pdf_path text,
  emailed_at timestamptz,
  created_at timestamptz default now()
);
create index on public.invoices(client_id);
alter table public.invoices enable row level security;
create policy inv_sel on public.invoices for select to authenticated using (client_id = (select auth.uid()) or public.is_admin());
create policy inv_upd on public.invoices for update to authenticated using (public.is_admin()) with check (public.is_admin());

create table if not exists private.counters (key text primary key, value int not null default 0);
create or replace function public.next_invoice_number(p_series text) returns text language plpgsql security definer set search_path = private, public as $$
declare k text := coalesce(nullif(p_series, ''), 'LM') || '-' || to_char(now() at time zone 'Europe/Madrid', 'YYYY'); v int;
begin
  insert into private.counters(key, value) values (k, 1) on conflict (key) do update set value = private.counters.value + 1 returning value into v;
  return k || '-' || lpad(v::text, 4, '0');
end $$;

create or replace function private.invoice_on_payment() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare s text; u text;
begin
  if new.status = 'pagado' and (tg_op = 'INSERT' or coalesce(old.status, '') <> 'pagado') then
    select value into u from private.config where key = 'notify_url';
    select value into s from private.config where key = 'notify_secret';
    if u is not null then
      perform net.http_post(url := replace(u, '/notify', '/invoice'), body := jsonb_build_object('payment_id', new.id),
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', s));
    end if;
  end if;
  return new;
end $$;
create trigger trg_invoice_on_payment after insert or update of status on public.payments for each row execute function private.invoice_on_payment();

-- ===== almacenamiento de archivos =====
insert into storage.buckets(id, name, public) values ('files', 'files', false) on conflict (id) do nothing;
insert into storage.buckets(id, name, public) values ('logos', 'logos', true) on conflict (id) do nothing;
create policy lm_files_sel on storage.objects for select to authenticated using (bucket_id = 'files' and (public.is_admin() or (storage.foldername(name))[1] = (select auth.uid())::text));
create policy lm_files_ins on storage.objects for insert to authenticated with check (bucket_id = 'files' and (public.is_admin() or (storage.foldername(name))[1] = (select auth.uid())::text));
create policy lm_files_rm on storage.objects for delete to authenticated using (bucket_id = 'files' and (public.is_admin() or (storage.foldername(name))[1] = (select auth.uid())::text));
create policy lm_logos_ins on storage.objects for insert to authenticated with check (bucket_id = 'logos' and (public.is_admin() or (storage.foldername(name))[1] = (select auth.uid())::text));
create policy lm_logos_upd on storage.objects for update to authenticated using (bucket_id = 'logos' and (public.is_admin() or (storage.foldername(name))[1] = (select auth.uid())::text));
create policy lm_logos_rm on storage.objects for delete to authenticated using (bucket_id = 'logos' and (public.is_admin() or (storage.foldername(name))[1] = (select auth.uid())::text));

-- ===== permisos y tiempo real =====
revoke execute on function public.request_meeting(jsonb) from public, anon;
revoke execute on function public.tick_need(uuid, int) from public, anon;
revoke execute on function public.report_payment(text, numeric, text, text) from public, anon;
revoke execute on function public.next_invoice_number(text) from public, anon, authenticated;
grant execute on function public.request_meeting(jsonb) to authenticated;
grant execute on function public.tick_need(uuid, int) to authenticated;
grant execute on function public.report_payment(text, numeric, text, text) to authenticated;
grant execute on function public.next_invoice_number(text) to service_role;
alter publication supabase_realtime add table public.posts, public.files, public.tasks, public.invoices;

-- ===== plantilla de factura por defecto =====
update public.settings set data = data || jsonb_build_object(
  'invoice', jsonb_build_object('name', 'La Muralla Project', 'nif', '', 'address', 'Ronda del Cañillo, 25', 'city', '45600 Talavera de la Reina (Toledo)',
    'email', 'hola@lamurallaproject.es', 'phone', '650 503 871', 'iban', '', 'series', 'LM', 'logo', '', 'color', '#DA7F2C',
    'footer', 'Gracias por confiar en La Muralla Local.', 'notes', ''),
  'payInfo', jsonb_build_object('paypal', '', 'iban', '', 'bizum', '', 'text', 'Indica en el concepto el nombre de tu negocio.')
) where id = 1;
