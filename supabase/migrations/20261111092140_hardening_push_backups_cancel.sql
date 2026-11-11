-- hardening_push_backups_cancel
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.config (key text primary key, value text not null);

-- avisos push
create table public.push_subs (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  sub jsonb not null,
  created_at timestamptz default now()
);
create index on public.push_subs(user_id);
alter table public.push_subs enable row level security;
create policy push_sel on public.push_subs for select to authenticated using (user_id = (select auth.uid()));
create policy push_ins on public.push_subs for insert to authenticated with check (user_id = (select auth.uid()));
create policy push_upd on public.push_subs for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy push_rm on public.push_subs for delete to authenticated using (user_id = (select auth.uid()));

create or replace function private.notify_push() returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare u text; s text;
begin
  select value into u from private.config where key = 'notify_url';
  select value into s from private.config where key = 'notify_secret';
  if u is not null then
    perform net.http_post(url := u, body := jsonb_build_object('table', TG_TABLE_NAME, 'record', to_jsonb(new)),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', s));
  end if;
  return new;
end $$;
create trigger trg_push_msg after insert on public.messages for each row execute function private.notify_push();
create trigger trg_push_ev after insert on public.events for each row execute function private.notify_push();
create trigger trg_push_bk after insert on public.bookings for each row execute function private.notify_push();

-- contraseñas de Instagram cifradas en Vault
create or replace function public.set_ig_password(p_user uuid, p_secret text) returns void language plpgsql security definer set search_path = public, vault as $$
declare sid uuid; nm text := 'ig_' || p_user::text;
begin
  if not (auth.uid() = p_user or public.is_admin() or coalesce(auth.role(), '') = 'service_role') then raise exception 'No permitido'; end if;
  if p_secret is null or length(p_secret) = 0 then return; end if;
  select id into sid from vault.secrets where name = nm;
  if sid is null then perform vault.create_secret(p_secret, nm); else perform vault.update_secret(sid, p_secret); end if;
  update public.profiles set onboarding = jsonb_set(coalesce(onboarding, '{}'::jsonb), '{igPass}', '"__vault__"'::jsonb) where id = p_user;
end $$;
create or replace function public.get_ig_password(p_user uuid) returns text language plpgsql security definer set search_path = public, vault as $$
declare s text;
begin
  if not public.is_admin() then raise exception 'Solo el equipo'; end if;
  select decrypted_secret into s from vault.decrypted_secrets where name = 'ig_' || p_user::text;
  return s;
end $$;

-- copias de seguridad diarias (14 días rotando)
create table if not exists private.backups (slot int primary key, taken_at timestamptz, data jsonb);
create or replace function public.export_data() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'exportado', now(),
    'settings', (select data from public.settings where id = 1),
    'profiles', (select coalesce(jsonb_agg(p), '[]'::jsonb) from public.profiles p),
    'availability', (select coalesce(jsonb_agg(a), '[]'::jsonb) from public.availability a),
    'bookings', (select coalesce(jsonb_agg(b), '[]'::jsonb) from public.bookings b),
    'extras', (select coalesce(jsonb_agg(e), '[]'::jsonb) from public.extras e),
    'events', (select coalesce(jsonb_agg(e), '[]'::jsonb) from public.events e),
    'payments', (select coalesce(jsonb_agg(p), '[]'::jsonb) from public.payments p),
    'messages', (select coalesce(jsonb_agg(m), '[]'::jsonb) from public.messages m)
  ) where public.is_admin() or coalesce(auth.role(), 'postgres') in ('service_role', 'postgres')
$$;
create or replace function private.take_backup() returns void language plpgsql security definer set search_path = public as $$
declare s int := (extract(doy from now())::int % 14);
begin
  insert into private.backups(slot, taken_at, data) values (s, now(), public.export_data())
  on conflict (slot) do update set taken_at = excluded.taken_at, data = excluded.data;
end $$;
select cron.schedule('copia-diaria', '15 3 * * *', $$select private.take_backup()$$);

-- bajas
alter table public.profiles add column if not exists cancel_requested_at timestamptz, add column if not exists end_date date;
create or replace function public.protect_profile() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role; new.username := old.username; new.pack := old.pack; new.price := old.price;
    new.promo := old.promo; new.status := old.status; new.start_date := old.start_date; new.scripts := old.scripts;
    new.mins := old.mins; new.paypal_subscription_id := old.paypal_subscription_id; new.is_demo := old.is_demo;
    new.end_date := old.end_date;
    if old.cancel_requested_at is not null then new.cancel_requested_at := old.cancel_requested_at; end if;
  end if;
  return new;
end $$;
create or replace function public.request_cancel() returns void language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found or p.role <> 'client' then raise exception 'No permitido'; end if;
  if p.cancel_requested_at is not null then raise exception 'Ya nos pediste la baja. Te escribimos por el chat.'; end if;
  update public.profiles set cancel_requested_at = now() where id = p.id;
  insert into public.messages(client_id, sender_id, from_team, who, text) values (p.id, p.id, false, coalesce(p.contact, 'Cliente'), 'He solicitado la baja de la membresía desde la app.');
end $$;

-- el equipo puede limpiar mensajes y pagos
create policy msg_adm_rm on public.messages for delete to authenticated using (public.is_admin());
create policy pay_adm_rm on public.payments for delete to authenticated using (public.is_admin());
create policy ev_adm_rm on public.events for delete to authenticated using (public.is_admin());
create policy extras_adm_rm on public.extras for delete to authenticated using (public.is_admin());

-- registros solo desde la app (las altas de la app llegan ya confirmadas)
create or replace function private.block_public_signup() returns trigger language plpgsql security definer as $$
begin
  if new.email_confirmed_at is null then
    raise exception 'Registro cerrado: las altas se hacen desde la app de La Muralla';
  end if;
  return new;
end $$;
create trigger trg_block_public_signup before insert on auth.users for each row execute function private.block_public_signup();

revoke execute on function public.set_ig_password(uuid, text) from public, anon;
revoke execute on function public.get_ig_password(uuid) from public, anon;
revoke execute on function public.export_data() from public, anon;
revoke execute on function public.request_cancel() from public, anon;
grant execute on function public.set_ig_password(uuid, text) to authenticated, service_role;
grant execute on function public.get_ig_password(uuid) to authenticated;
grant execute on function public.export_data() to authenticated, service_role;
grant execute on function public.request_cancel() to authenticated;
