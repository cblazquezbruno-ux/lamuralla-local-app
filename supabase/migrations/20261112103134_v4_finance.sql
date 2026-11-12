create table public.finance (
  id uuid primary key default gen_random_uuid(),
  date date not null default ((now() at time zone 'Europe/Madrid')::date),
  kind text not null check (kind in ('ingreso','gasto')),
  area text not null default 'general' check (area in ('labs','local','studio','general')),
  category text,
  concept text not null,
  amount numeric not null check (amount >= 0),
  iva_pct numeric not null default 21,
  client_id uuid references public.profiles(id) on delete set null,
  file_path text,
  note text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz default now()
);
create index on public.finance(date);
alter table public.finance enable row level security;
create policy fin_all on public.finance for all to authenticated using (public.is_admin()) with check (public.is_admin());
alter publication supabase_realtime add table public.finance;
