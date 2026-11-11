-- function_grants
revoke execute on function public.taken_slots() from public, anon;
revoke execute on function public.book_slot(date, text, date) from public, anon;
revoke execute on function public.set_extra_days(text, int) from public, anon;
revoke execute on function public.respond_event(uuid, boolean) from public, anon;
revoke execute on function public.mark_read(uuid) from public, anon;
revoke execute on function public.protect_profile() from public, anon, authenticated;
grant execute on function public.taken_slots() to authenticated;
grant execute on function public.book_slot(date, text, date) to authenticated;
grant execute on function public.set_extra_days(text, int) to authenticated;
grant execute on function public.respond_event(uuid, boolean) to authenticated;
grant execute on function public.mark_read(uuid) to authenticated;
