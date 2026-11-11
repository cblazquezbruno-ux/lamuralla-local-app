import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const MES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];

async function paypalToken(env: string) {
  const id = Deno.env.get('PAYPAL_CLIENT_ID'), sec = Deno.env.get('PAYPAL_SECRET');
  if (!id || !sec) return null;
  const base = env === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com';
  const r = await fetch(base + '/v1/oauth2/token', { method: 'POST', headers: { Authorization: 'Basic ' + btoa(id + ':' + sec), 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'grant_type=client_credentials' });
  if (!r.ok) return null;
  return { token: (await r.json()).access_token as string, base };
}

// Cobra los extras del mes (días extra y eventos aceptados), comprobando el pago en PayPal.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: u } = await admin.auth.getUser((req.headers.get('Authorization') || '').replace('Bearer ', ''));
    if (!u?.user) return json({ error: 'Inicia sesión' }, 401);
    const uid = u.user.id;
    const body = await req.json();
    const month = String(body.month || '');
    if (!/^\d{4}-\d{2}$/.test(month)) return json({ error: 'Mes no válido' }, 400);

    const { data: st } = await admin.from('settings').select('data').eq('id', 1).single();
    const s = st!.data;
    const { data: prof } = await admin.from('profiles').select('iva_pct').eq('id', uid).single();
    const iva = prof?.iva_pct !== null && prof?.iva_pct !== undefined ? Number(prof.iva_pct) : Number(s.iva ?? 21);
    const { data: ex } = await admin.from('extras').select('*').eq('client_id', uid).eq('month', month).maybeSingle();
    const { data: evs } = await admin.from('events').select('*').eq('client_id', uid).eq('month', month).eq('status', 'aceptado').eq('paid', false);
    let base = 0;
    const daysToPay = ex ? Math.max(0, ex.days - ex.paid_days) : 0;
    base += daysToPay * Number(ex?.day_price ?? s.extraDay);
    for (const e of evs || []) base += Number(e.quote || 0);
    if (base <= 0) return json({ error: 'No tienes nada pendiente' }, 400);
    const total = Math.round(base * (1 + iva / 100) * 100) / 100;

    let method = 'prueba', paypalId: string | null = null;
    if (body.orderId) {
      const t = await paypalToken(s.paypal?.env || 'sandbox');
      if (!t) return json({ error: 'PayPal no está configurado en el servidor' }, 500);
      const r = await fetch(t.base + '/v2/checkout/orders/' + encodeURIComponent(body.orderId), { headers: { Authorization: 'Bearer ' + t.token } });
      const o = await r.json();
      const paid = o?.purchase_units?.[0]?.payments?.captures?.[0];
      if (!r.ok || o.status !== 'COMPLETED' || !paid) return json({ error: 'No hemos podido confirmar el pago en PayPal' }, 402);
      if (Math.abs(Number(paid.amount.value) - total) > 0.02) return json({ error: 'El importe pagado no coincide' }, 402);
      method = 'paypal'; paypalId = body.orderId;
    } else if (!s.paypal?.testMode) {
      return json({ error: 'Falta el pago' }, 402);
    }

    if (ex && daysToPay) await admin.from('extras').update({ paid_days: ex.days }).eq('client_id', uid).eq('month', month);
    if (evs?.length) await admin.from('events').update({ paid: true }).in('id', evs.map((e: any) => e.id));
    const m = MES[Number(month.slice(5, 7)) - 1];
    await admin.from('payments').insert({ client_id: uid, concept: `Extras de ${m}`, base, method, paypal_id: paypalId, iva });
    return json({ ok: true, base, total });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
