create trigger trg_push_files after insert on public.files for each row execute function private.notify_push();
create trigger trg_push_tasks after insert on public.tasks for each row execute function private.notify_push();
create trigger trg_push_posts after insert on public.posts for each row execute function private.notify_push();
-- facturas: el equipo puede ver los contadores vía función
create or replace function public.invoice_preview_number() returns text language sql stable security definer set search_path = private, public as $$
  select coalesce((select data->'invoice'->>'series' from public.settings where id=1),'LM') || '-' || to_char(now() at time zone 'Europe/Madrid','YYYY') || '-' ||
         lpad((coalesce((select value from private.counters where key = coalesce((select data->'invoice'->>'series' from public.settings where id=1),'LM') || '-' || to_char(now() at time zone 'Europe/Madrid','YYYY')),0)+1)::text,4,'0')
$$;
revoke execute on function public.invoice_preview_number() from public, anon;
grant execute on function public.invoice_preview_number() to authenticated;
