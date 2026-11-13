create or replace function public.recovery_set(p_user uuid, p_hash text) returns boolean language plpgsql security definer set search_path = private, public as $$
begin
  if exists (select 1 from private.recovery where user_id = p_user and expires_at > now() + interval '14 minutes') then return false; end if;
  insert into private.recovery(user_id, code_hash, expires_at, tries) values (p_user, p_hash, now() + interval '15 minutes', 0)
  on conflict (user_id) do update set code_hash = excluded.code_hash, expires_at = excluded.expires_at, tries = 0;
  return true;
end $$;
create or replace function public.recovery_check(p_user uuid, p_hash text) returns boolean language plpgsql security definer set search_path = private, public as $$
declare r record;
begin
  select * into r from private.recovery where user_id = p_user for update;
  if not found or r.expires_at < now() or r.tries >= 5 then return false; end if;
  if r.code_hash = p_hash then delete from private.recovery where user_id = p_user; return true; end if;
  update private.recovery set tries = tries + 1 where user_id = p_user; return false;
end $$;
revoke execute on function public.recovery_set(uuid, text) from public, anon, authenticated;
revoke execute on function public.recovery_check(uuid, text) from public, anon, authenticated;
grant execute on function public.recovery_set(uuid, text) to service_role;
grant execute on function public.recovery_check(uuid, text) to service_role;
