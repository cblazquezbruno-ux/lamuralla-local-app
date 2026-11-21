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
    'packs', (select jsonb_agg(jsonb_build_object('id', p->>'id', 'name', p->>'name', 'tagline', p->>'tagline', 'features', p->'features',
        'price', case when promo or l.slot_taken then p->'promo' else p->'price' end, 'listPrice', p->'price',
        'setup', case when promo or l.slot_taken then coalesce(p->'promoSetup', p->'setup') else p->'setup' end)) from jsonb_array_elements(s->'packs') p));
end $$;
grant execute on function public.lead_offer(text) to anon, authenticated;
