import { createClient } from 'npm:@supabase/supabase-js@2';

const MES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];

async function paypalToken(env: string) {
  const id = Deno.env.get('PAYPAL_CLIENT_ID'), sec = Deno.env.get('PAYPAL_SECRET');
  if (!id || !sec) return null;
  const base = env === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com';
  const r = await fetch(base + '/v1/oauth2/token', { method: 'POST', headers: { Authorization: 'Basic ' + btoa(id + ':' + sec), 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'grant_type=client_credentials' });
  if (!r.ok) return null;
  return { token: (await r.json()).access_token as string, base };
}

// PayPal avisa aquí de cada cobro mensual de la membresía y de cancelaciones o impagos.
Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('ok');
  const raw = await req.text();
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: st } = await admin.from('settings').select('data').eq('id', 1).single();
  const env = st?.data?.paypal?.env || 'sandbox';
  const webhookId = Deno.env.get('PAYPAL_WEBHOOK_ID');
  const t = await paypalToken(env);
  if (!t || !webhookId) return new Response('not configured', { status: 503 });

  const h = (k: string) => req.headers.get(k) || '';
  const v = await fetch(t.base + '/v1/notifications/verify-webhook-signature', {
    method: 'POST', headers: { Authorization: 'Bearer ' + t.token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ auth_algo: h('paypal-auth-algo'), cert_url: h('paypal-cert-url'), transmission_id: h('paypal-transmission-id'), transmission_sig: h('paypal-transmission-sig'), transmission_time: h('paypal-transmission-time'), webhook_id: webhookId, webhook_event: JSON.parse(raw) })
  });
  const vj = await v.json();
  if (vj.verification_status !== 'SUCCESS') return new Response('bad signature', { status: 400 });

  const ev = JSON.parse(raw);
  const r = ev.resource || {};
  const subId = r.billing_agreement_id || r.id;
  const { data: prof } = await admin.from('profiles').select('id,pack,price,iva_pct,custom_pack').eq('paypal_subscription_id', subId).maybeSingle();
  if (!prof) return new Response('ok');
  const iva = prof.iva_pct !== null && prof.iva_pct !== undefined ? Number(prof.iva_pct) : Number(st?.data?.iva ?? 21);

  if (ev.event_type === 'PAYMENT.SALE.COMPLETED') {
    const { data: dup } = await admin.from('payments').select('id').eq('paypal_id', r.id).maybeSingle();
    const { count } = await admin.from('payments').select('id', { count: 'exact', head: true }).eq('client_id', prof.id);
    if (!dup && (count || 0) > 0) {
      const now = new Date();
      const pack = prof.custom_pack?.name || (prof.pack === 'completo' ? 'Pack Completo' : 'Pack Imagen');
      await admin.from('payments').insert({ client_id: prof.id, concept: `Cuota ${MES[now.getMonth()]} · ${pack}`, base: prof.price, method: 'paypal', paypal_id: r.id, iva });
    }
    await admin.from('profiles').update({ status: 'activa' }).eq('id', prof.id);
  }
  if (['BILLING.SUBSCRIPTION.PAYMENT.FAILED', 'BILLING.SUBSCRIPTION.SUSPENDED'].includes(ev.event_type)) {
    await admin.from('profiles').update({ status: 'pausa' }).eq('id', prof.id);
    await admin.from('messages').insert({ client_id: prof.id, from_team: true, who: 'La Muralla', text: 'No hemos podido cobrar tu cuota en PayPal. Revisa tu método de pago para que no se pare el servicio. Si necesitas ayuda, escríbenos por aquí.' });
  }
  if (ev.event_type === 'BILLING.SUBSCRIPTION.CANCELLED') {
    await admin.from('profiles').update({ status: 'baja' }).eq('id', prof.id);
  }
  return new Response('ok');
});
