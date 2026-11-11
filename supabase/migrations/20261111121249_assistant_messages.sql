-- assistant_messages
create table public.assistant_messages (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  text text not null,
  created_at timestamptz default now()
);
create index on public.assistant_messages(user_id, created_at);
alter table public.assistant_messages enable row level security;
-- privado: cada usuario solo ve su propia conversación con el asistente (ni siquiera el equipo)
create policy am_sel on public.assistant_messages for select to authenticated using (user_id = (select auth.uid()));
create policy am_rm on public.assistant_messages for delete to authenticated using (user_id = (select auth.uid()));
