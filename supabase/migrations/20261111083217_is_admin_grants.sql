-- is_admin_grants
revoke execute on function public.is_admin() from public, anon; grant execute on function public.is_admin() to authenticated; revoke execute on function public.today_es() from anon;
