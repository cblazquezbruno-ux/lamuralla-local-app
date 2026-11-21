-- ===== datos públicos de la campaña (solo cifras) =====
create table public.campaign_public (
  id int primary key default 1 check (id = 1),
  total int not null default 10, taken int not null default 0, active boolean not null default true,
  ends_at timestamptz, city text, updated_at timestamptz default now()
);
alter table public.campaign_public enable row level security;
create policy cp_sel on public.campaign_public for select to anon, authenticated using (true);
grant select on public.campaign_public to anon, authenticated;

create or replace function private.sync_campaign() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.campaign_public(id, total, taken, active, ends_at, city, updated_at)
  values (1, coalesce((new.data->>'promoTotal')::int, 10), coalesce((new.data->>'promoTaken')::int, 0), coalesce((new.data->>'promoOn')::boolean, true),
          nullif(new.data->>'promoEnds','')::timestamptz, new.data->>'city', now())
  on conflict (id) do update set total = excluded.total, taken = excluded.taken, active = excluded.active, ends_at = excluded.ends_at, city = excluded.city, updated_at = now()
  where (campaign_public.total, campaign_public.taken, campaign_public.active, campaign_public.ends_at, campaign_public.city) is distinct from (excluded.total, excluded.taken, excluded.active, excluded.ends_at, excluded.city);
  return new;
end $$;
create trigger trg_sync_campaign after insert or update of data on public.settings for each row execute function private.sync_campaign();
update public.settings set data = data || jsonb_build_object('promoEnds', '2026-12-25T23:59:00+01:00', 'promoTotal', 10, 'promoTaken', 0, 'promoShowPrice', false) where id = 1;
alter publication supabase_realtime add table public.campaign_public;

-- ===== solicitudes de la landing =====
create table public.leads (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  business text not null, sector text, contact text not null, phone text not null, email text, zone text, social text, need text,
  ref_code text, referrer uuid references public.profiles(id) on delete set null,
  status text not null default 'pendiente' check (status in ('pendiente','aprobada','rechazada','convertida')),
  token text unique, approved_by uuid references public.profiles(id) on delete set null, approved_at timestamptz,
  rejected_reason text, rejected_at timestamptz, slot_taken boolean not null default false,
  profile_id uuid references public.profiles(id) on delete set null, notified jsonb not null default '{}'::jsonb,
  note text, privacy_at timestamptz not null default now(), ip_hash text, user_agent text, source text
);
create index on public.leads(status, created_at desc);
alter table public.leads enable row level security;
create policy leads_adm on public.leads for all to authenticated using (public.is_admin()) with check (public.is_admin());
alter publication supabase_realtime add table public.leads;

create or replace function private.adjust_taken(p_delta int) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.settings set data = jsonb_set(data, '{promoTaken}', to_jsonb(greatest(0, coalesce((data->>'promoTaken')::int,0) + p_delta))) where id = 1;
end $$;

create or replace function public.lead_approve(p_id uuid) returns text language plpgsql security definer set search_path = public, extensions as $$
declare t text;
begin
  if not public.is_admin() then raise exception 'Solo el equipo'; end if;
  select token into t from public.leads where id = p_id;
  if t is null then t := encode(gen_random_bytes(18), 'hex'); end if;
  update public.leads set status = case when status = 'convertida' then status else 'aprobada' end, token = t, approved_by = auth.uid(), approved_at = coalesce(approved_at, now()), rejected_reason = null, rejected_at = null where id = p_id;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  return t;
end $$;

create or replace function public.lead_reject(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo el equipo'; end if;
  update public.leads set status = 'rechazada', rejected_reason = nullif(trim(p_reason),''), rejected_at = now(), token = null where id = p_id and status <> 'convertida';
end $$;

create or replace function public.lead_set_slot(p_id uuid, p_on boolean) returns void language plpgsql security definer set search_path = public, private as $$
declare cur boolean;
begin
  if not public.is_admin() then raise exception 'Solo el equipo'; end if;
  select slot_taken into cur from public.leads where id = p_id for update;
  if cur is null then raise exception 'Solicitud no encontrada'; end if;
  if cur = p_on then return; end if;
  update public.leads set slot_taken = p_on where id = p_id;
  perform private.adjust_taken(case when p_on then 1 else -1 end);
end $$;

-- lo que ve el negocio aprobado con su enlace privado
create or replace function public.lead_offer(p_token text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l record; s jsonb; promo boolean;
begin
  if p_token is null or length(p_token) < 20 then return null; end if;
  select * into l from public.leads where token = p_token and status in ('aprobada','convertida');
  if not found then return null; end if;
  select data into s from public.settings where id = 1;
  promo := coalesce((s->>'promoOn')::boolean, false) and coalesce((s->>'promoTaken')::int,0) < coalesce((s->>'promoTotal')::int,0)
           and (nullif(s->>'promoEnds','') is null or now() < (s->>'promoEnds')::timestamptz);
  return jsonb_build_object('status', l.status, 'business', l.business, 'contact', l.contact, 'phone', l.phone, 'email', l.email, 'sector', l.sector, 'ref', l.ref_code,
    'promo', promo or l.slot_taken, 'iva', s->'iva', 'minMonths', s->'minMonths', 'noticeDays', s->'noticeDays', 'extraDay', s->'extraDay', 'endsAt', s->'promoEnds',
    'packs', (select jsonb_agg(jsonb_build_object('id', p->>'id', 'name', p->>'name', 'tag', p->>'tag', 'features', p->'features',
        'price', case when promo or l.slot_taken then p->'promo' else p->'price' end, 'listPrice', p->'price',
        'setup', case when promo or l.slot_taken then coalesce(p->'promoSetup', p->'setup') else p->'setup' end)) from jsonb_array_elements(s->'packs') p));
end $$;

revoke execute on function public.lead_approve(uuid) from public, anon;
revoke execute on function public.lead_reject(uuid, text) from public, anon;
revoke execute on function public.lead_set_slot(uuid, boolean) from public, anon;
grant execute on function public.lead_approve(uuid) to authenticated;
grant execute on function public.lead_reject(uuid, text) to authenticated;
grant execute on function public.lead_set_slot(uuid, boolean) to authenticated;
grant execute on function public.lead_offer(text) to anon, authenticated;

create trigger trg_push_leads after insert on public.leads for each row execute function private.notify_push();
