-- signup_allowlist
create table if not exists private.signup_allow (email text primary key, created_at timestamptz default now());
create or replace function public.allow_signup(p_email text) returns void language sql security definer set search_path = private as $$
  insert into private.signup_allow(email) values (lower(p_email)) on conflict (email) do nothing
$$;
revoke execute on function public.allow_signup(text) from public, anon, authenticated;
grant execute on function public.allow_signup(text) to service_role;
create or replace function private.block_public_signup() returns trigger language plpgsql security definer set search_path = private as $$
begin
  if not exists (select 1 from private.signup_allow a where a.email = lower(new.email)) then
    raise exception 'Registro cerrado: las altas se hacen desde la app de La Muralla';
  end if;
  return new;
end $$;
