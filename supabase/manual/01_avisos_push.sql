-- Configuración de los avisos push (se ejecuta una vez a mano en el SQL Editor de Supabase).
-- NO subas a GitHub los valores reales: genera tus claves y pégalas solo en Supabase.
-- Claves VAPID:  npx web-push generate-vapid-keys
-- Secreto:       cualquier texto largo aleatorio
insert into private.config(key, value) values
  ('notify_url',    'https://TU-PROYECTO.supabase.co/functions/v1/notify'),
  ('notify_secret', 'PEGA_AQUI_UN_SECRETO_LARGO'),
  ('vapid_public',  'PEGA_AQUI_LA_CLAVE_PUBLICA_VAPID'),
  ('vapid_private', 'PEGA_AQUI_LA_CLAVE_PRIVADA_VAPID'),
  ('vapid_subject', 'mailto:hola@lamurallaproject.es')
on conflict (key) do update set value = excluded.value;

create or replace function public.push_config() returns jsonb language sql stable security definer set search_path = private as
$$ select jsonb_object_agg(key, value) from private.config $$;
revoke execute on function public.push_config() from public, anon, authenticated;
grant execute on function public.push_config() to service_role;
-- La clave pública VAPID también va en el frontend: CFG.vapid en source/app.src.html
