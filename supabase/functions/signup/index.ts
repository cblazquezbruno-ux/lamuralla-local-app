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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const body = await req.json();
    const f = body.form || {};
    const packId = body.pack === 'completo' ? 'completo' : 'imagen';
    const pay = body.payment || {};

    let byTeam = false;
    const auth = req.headers.get('Authorization') || '';
    if (auth.startsWith('Bearer ') && body.byTeam) {
      const { data: u } = await admin.auth.getUser(auth.slice(7));
      if (u?.user) {
        const { data: p } = await admin.from('profiles').select('role').eq('id', u.user.id).single();
        byTeam = p?.role === 'admin';
      }
      if (!byTeam) return json({ error: 'Solo el equipo puede dar altas manuales' }, 403);
    }

    const username = norm(f.user);
    if (!/^[a-z0-9._-]{3,30}$/.test(username)) return json({ error: 'El usuario solo puede tener letras, números, puntos o guiones (3-30)' }, 400);
    if (!f.pass || String(f.pass).length < 6) return json({ error: 'La contraseña debe tener al menos 6 caracteres' }, 400);
    if (!f.business || !f.contact) return json({ error: 'Faltan datos del negocio' }, 400);
    const { data: exists } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
    if (exists) return json({ error: 'Ese usuario ya existe. Prueba con otro.' }, 409);

    const { data: st } = await admin.from('settings').select('data').eq('id', 1).single();
    const s = st!.data;
    const pack = s.packs.find((p: any) => p.id === packId);
    const promo = !!(s.promoOn && s.promoTaken < s.promoTotal);
    const cu = byTeam && body.custom ? body.custom : null; // cliente especial creado por el equipo
    let base = promo ? pack.promo : pack.price;
    const setup = pack.setup ? (promo ? pack.promoSetup : pack.setup) : 0;
    if (cu && cu.price !== undefined && cu.price !== null && cu.price !== '') base = Number(cu.price);
    const ivaPct = cu && cu.iva !== undefined && cu.iva !== null && cu.iva !== '' ? Number(cu.iva) : null;

    let method = 'prueba', paypalId: string | null = null, subId: string | null = null;
    if (!byTeam) {
      if (pay.mode === 'paypal' && pay.subscriptionId) {
        const t = await paypalToken(s.paypal?.env || 'sandbox');
        if (!t) return json({ error: 'PayPal no está configurado en el servidor' }, 500);
        const r = await fetch(t.base + '/v1/billing/subscriptions/' + encodeURIComponent(pay.subscriptionId), { headers: { Authorization: 'Bearer ' + t.token } });
        const sub = await r.json();
        if (!r.ok || !['ACTIVE', 'APPROVED'].includes(sub.status)) return json({ error: 'No hemos podido confirmar el pago en PayPal' }, 402);
        method = 'paypal'; paypalId = pay.subscriptionId; subId = pay.subscriptionId;
      } else if (s.paypal?.testMode) {
        method = 'prueba';
      } else {
        return json({ error: 'Falta el pago' }, 402);
      }
    } else method = 'manual';

    const email = `${username}@${DOMAIN}`;
    await admin.rpc('allow_signup', { p_email: email });
    const { data: created, error: e1 } = await admin.auth.admin.createUser({ email, password: String(f.pass), email_confirm: true, user_metadata: { business: f.business } });
    if (e1) return json({ error: e1.message }, 400);
    const uid = created.user!.id;

    const onboarding = { goals: f.goals || [], style: f.style || [], best: f.best || '', audience: f.audience || '', refs: f.refs || '', avoid: f.avoid || '', ig: f.ig || '', tiktok: f.tiktok || '', google: f.google || '', access: f.access || 'partner', igUser: f.igUser || '', igPass: '' };
    const isTest = method === 'prueba'; // las altas de prueba no gastan plaza de campaña
    let referrer: string | null = null;
    if (body.ref) { const { data: rf } = await admin.from('profiles').select('id').eq('referral_code', String(body.ref).toUpperCase().trim()).eq('role', 'client').maybeSingle(); referrer = rf?.id || null; }
    const { error: e2 } = await admin.from('profiles').insert({ referred_by: referrer, id: uid, role: 'client', username, business: f.business, contact: f.contact, phone: f.phone || null, email: f.email || null, sector: f.sector || 'otro', pack: packId, price: base, onboarding, paypal_subscription_id: subId, is_demo: isTest, iva_pct: ivaPct, custom_pack: cu?.pack?.name ? { name: String(cu.pack.name), features: (cu.pack.features || []).map(String) } : null, extra_day_price: cu && cu.extraDay ? Number(cu.extraDay) : null, promo: cu ? false : promo });
    if (e2) { await admin.auth.admin.deleteUser(uid); return json({ error: e2.message }, 400); }
    if (f.access === 'password' && f.igPass) await admin.rpc('set_ig_password', { p_user: uid, p_secret: String(f.igPass) });

    if (referrer) await admin.from('referrals').insert({ referrer, referred: uid, referred_name: f.business });
    if (!byTeam) await admin.from('payments').insert({ client_id: uid, concept: `Primer mes · ${pack.name} (adelantado)` + (setup ? ' + alta asistente' : ''), base: base + setup, method, paypal_id: paypalId, iva: Number(s.iva ?? 21) });
    const { data: team } = await admin.from('profiles').select('id').eq('role', 'admin').limit(1).maybeSingle();
    await admin.from('messages').insert({ client_id: uid, sender_id: team?.id ?? null, from_team: true, who: 'José Pedro', text: `¡Bienvenido/a, ${String(f.contact).split(' ')[0]}! Soy José Pedro, tu responsable de cuenta. Primero firma tu contrato desde Inicio (es un minuto) y pide la reunión de arranque: ahí vemos tus objetivos, accesos y qué vamos a grabar. Después eliges tu día de rodaje.` });
    if (promo && !isTest && !cu) { s.promoTaken = (s.promoTaken || 0) + 1; await admin.from('settings').update({ data: s, updated_at: new Date().toISOString() }).eq('id', 1); }

    return json({ ok: true, username, email });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
