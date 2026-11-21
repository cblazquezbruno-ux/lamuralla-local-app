create or replace function public.public_settings(p_token text default null) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s jsonb; ok boolean := false; inv jsonb;
begin
  select data into s from public.settings where id = 1;
  if p_token is not null and length(p_token) >= 20 then
    ok := exists (select 1 from public.leads where token = p_token and status in ('aprobada','convertida'));
  end if;
  inv := coalesce(s->'invoice','{}'::jsonb);
  s := s - 'contract' - 'payInfo' - 'need' - 'backup';
  s := jsonb_set(s, '{invoice}', jsonb_build_object('name', inv->'name', 'nif', inv->'nif', 'address', inv->'address', 'city', inv->'city', 'email', inv->'email', 'phone', inv->'phone', 'logo', inv->'logo'));
  if coalesce((s->>'promoShowPrice')::boolean, false) or ok then
    s := s || jsonb_build_object('fromPrice', (select min((p->>'promo')::numeric) from jsonb_array_elements(s->'packs') p));
  end if;
  if not ok then
    s := jsonb_set(s, '{packs}', coalesce((select jsonb_agg(p - 'price' - 'promo' - 'setup' - 'promoSetup') from jsonb_array_elements(s->'packs') p), '[]'::jsonb));
    s := s - 'extraDay';
  end if;
  return s || jsonb_build_object('leadOk', ok);
end $$;
grant execute on function public.public_settings(text) to anon, authenticated;
drop policy if exists settings_sel on public.settings;
create policy settings_sel on public.settings for select to authenticated using (true);
