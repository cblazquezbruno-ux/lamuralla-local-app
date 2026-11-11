import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const DOMAIN = 'app.lamurallaproject.es';
const norm = (s: string) => String(s || '').toLowerCase().replace(/\s+/g, '').normalize('NFD').replace(/[̀-ͯ]/g, '');

async function paypalToken(env: string) {
  const id = Deno.env.get('PAYPAL_CLIENT_ID'), sec = Deno.env.get('PAYPAL_SECRET');
  if (!id || !sec) return null;
  const base = env === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com';
  const r = await fetch(base + '/v1/oauth2/token', { method: 'POST', headers: { Authorization: 'Basic ' + btoa(id + ':' + sec), 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'grant_type=client_credentials' });
  if (!r.ok) return null;
  return { token: (await r.json()).access_token as string, base };
}

// Acciones solo para el equipo.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: u } = await admin.auth.getUser((req.headers.get('Authorization') || '').replace('Bearer ', ''));
    if (!u?.user) return json({ error: 'Inicia sesión' }, 401);
    const { data: me } = await admin.from('profiles').select('role,contact').eq('id', u.user.id).single();
    if (me?.role !== 'admin') return json({ error: 'Solo el equipo' }, 403);
    const b = await req.json();

    if (b.action === 'reset_password') {
      if (!b.password || String(b.password).length < 6) return json({ error: 'Mínimo 6 caracteres' }, 400);
      const { error } = await admin.auth.admin.updateUserById(b.userId, { password: String(b.password) });
      return error ? json({ error: error.message }, 400) : json({ ok: true });
    }
    if (b.action === 'create_admin') {
      const username = norm(b.user);
      if (!/^[a-z0-9._-]{3,30}$/.test(username)) return json({ error: 'Usuario no válido' }, 400);
      if (!b.password || String(b.password).length < 6) return json({ error: 'Mínimo 6 caracteres' }, 400);
      const email = `${username}@${DOMAIN}`;
      await admin.rpc('allow_signup', { p_email: email });
      const { data: c, error } = await admin.auth.admin.createUser({ email, password: String(b.password), email_confirm: true });
      if (error) return json({ error: error.message }, 400);
      await admin.from('profiles').insert({ id: c.user!.id, role: 'admin', username, business: 'Equipo La Muralla', contact: b.name || username, price: 0 });
      return json({ ok: true });
    }
    if (b.action === 'confirm_cancel') {
      const { data: p } = await admin.from('profiles').select('*').eq('id', b.userId).single();
      if (!p || p.role !== 'client') return json({ error: 'Cliente no encontrado' }, 404);
      const end = String(b.endDate || '').slice(0, 10);
      if (!/^\d{4}-\d{2}-\d{2}$/.test(end)) return json({ error: 'Fecha de fin no válida' }, 400);
      let paypal = 'sin suscripción de PayPal';
      if (p.paypal_subscription_id) {
        const { data: st } = await admin.from('settings').select('data').eq('id', 1).single();
        const t = await paypalToken(st?.data?.paypal?.env || 'sandbox');
        if (!t) paypal = 'PayPal no configurado: cancélala a mano en PayPal';
        else {
          const r = await fetch(`${t.base}/v1/billing/subscriptions/${encodeURIComponent(p.paypal_subscription_id)}/cancel`, { method: 'POST', headers: { Authorization: 'Bearer ' + t.token, 'Content-Type': 'application/json' }, body: JSON.stringify({ reason: 'Baja solicitada por el cliente' }) });
          paypal = r.ok || r.status === 204 ? 'suscripción de PayPal cancelada' : 'no se pudo cancelar en PayPal: revísalo a mano';
        }
      }
      await admin.from('profiles').update({ status: 'baja', end_date: end }).eq('id', p.id);
      await admin.from('messages').insert({ client_id: p.id, sender_id: u.user.id, from_team: true, who: me.contact || 'La Muralla', text: `Hemos tramitado tu baja. Tu último día con nosotros es el ${end.split('-').reverse().join('/')}. No se te cobrarán más cuotas. ¡Gracias por confiar en La Muralla!` });
      return json({ ok: true, paypal });
    }
    if (b.action === 'delete_client') {
      const { data: p } = await admin.from('profiles').select('role').eq('id', b.userId).single();
      if (p?.role !== 'client') return json({ error: 'Solo se pueden borrar clientes' }, 400);
      const { error } = await admin.auth.admin.deleteUser(b.userId);
      return error ? json({ error: error.message }, 400) : json({ ok: true });
    }
    if (b.action === 'delete_member') {
      if (b.userId === u.user.id) return json({ error: 'No puedes borrar tu propia cuenta' }, 400);
      const { error } = await admin.auth.admin.deleteUser(b.userId);
      return error ? json({ error: error.message }, 400) : json({ ok: true });
    }
    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
