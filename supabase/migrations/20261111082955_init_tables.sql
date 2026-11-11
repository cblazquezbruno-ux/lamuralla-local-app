-- init_tables
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'client' check (role in ('client','admin')),
  username text unique not null,
  business text, contact text, phone text, email text,
  sector text default 'hosteleria',
  pack text default 'imagen',
  price numeric default 390,
  promo boolean default false,
  start_date date default ((now() at time zone 'Europe/Madrid')::date),
  status text default 'activa',
  onboarding jsonb default '{}'::jsonb,
  checks jsonb default '{}'::jsonb,
  scripts text[] default '{}',
  approved boolean default false,
  mins int default 0,
  paypal_subscription_id text,
  is_demo boolean default false,
  created_at timestamptz default now()
);
create table public.settings (id int primary key default 1 check (id = 1), data jsonb not null, updated_at timestamptz default now());
create table public.availability (date date primary key, slots text[] not null default '{}');
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  date date not null, slot text not null, created_at timestamptz default now(),
  unique(date, slot)
);
create table public.extras (
  client_id uuid not null references public.profiles(id) on delete cascade,
  month text not null, days int not null default 0, paid_days int not null default 0, day_price numeric not null default 120,
  primary key (client_id, month)
);
create table public.events (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  title text not null, text text, date date, status text not null default 'pendiente',
  quote numeric, reply text, month text, paid boolean default false, created_at timestamptz default now()
);
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  date date default ((now() at time zone 'Europe/Madrid')::date),
  concept text, base numeric not null default 0, status text default 'pagado', method text default 'paypal', paypal_id text,
  created_at timestamptz default now()
);
create table public.messages (
  id bigint generated always as identity primary key,
  client_id uuid not null references public.profiles(id) on delete cascade,
  sender_id uuid, from_team boolean not null default false, who text, text text not null,
  read_by_client boolean default false, read_by_team boolean default false,
  created_at timestamptz default now()
);
create index on public.messages(client_id, created_at);
create index on public.bookings(client_id);
create index on public.events(client_id);
create index on public.payments(client_id);
create index on public.extras(client_id);
