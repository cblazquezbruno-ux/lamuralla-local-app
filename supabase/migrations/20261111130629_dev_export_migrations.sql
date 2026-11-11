create or replace function public.dev_migrations() returns table(version text, name text, statements text[]) language sql stable security definer set search_path = supabase_migrations, public as $$
  select m.version, m.name, m.statements from supabase_migrations.schema_migrations m where public.is_admin() order by m.version
$$;
revoke execute on function public.dev_migrations() from public, anon;
grant execute on function public.dev_migrations() to authenticated;
