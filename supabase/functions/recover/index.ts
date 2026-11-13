import { createClient } from 'npm:@supabase/supabase-js@2';

// Recuperar contraseña sin el equipo: manda un código de 6 cifras al email del cliente (con Resend) y permite poner una nueva.
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const norm = (s: string) => String(s || '').toLowerCase().replace(/\s+/g, '').normalize('NFD').replace(/[̀-ͯ]/g, '');
const sha = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))).map((b) => b.toString(16).padStart(2, '0')).join('');
const mask = (e: string) => e.replace(/^(.)(.*)(@.*)$/, (_, a, b, c) => a + '•'.repeat(Math.min(6, b.length)) + c);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));
    const { data: p } = await admin.from('profiles').select('id,contact,email,billing').eq('username', norm(b.user)).maybeSingle();
    const email = p ? (p.email || p.billing?.email || '') : '';
    const key = Deno.env.get('RESEND_API_KEY');
    if (b.action === 'send') {
      if (!key) return json({ ok: false, reason: 'off' });
      if (!p || !email) return json({ ok: false, reason: 'noemail' });
      const code = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, '0');
      const { data: ok } = await admin.rpc('recovery_set', { p_user: p.id, p_hash: await sha(code + p.id) });
      if (!ok) return json({ ok: false, reason: 'wait' });
      const { data: st } = await admin.from('settings').select('data').eq('id', 1).single();
      const from = Deno.env.get('INVOICE_FROM') || `${st?.data?.invoice?.name || 'La Muralla'} <facturas@lamurallaproject.es>`;
      const r = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from, to: [email], subject: `Tu código: ${code} · La Muralla Local`, html: `<p>Hola ${p.contact || ''},</p><p>Tu código para cambiar la contraseña de la app es:</p><p style="font-size:28px;font-weight:700;letter-spacing:6px">${code}</p><p>Caduca en 15 minutos. Si no lo has pedido tú, ignora este email.</p>` }) });
      if (!r.ok) return json({ ok: false, reason: 'mail' });
      return json({ ok: true, to: mask(email) });
    }
    if (b.action === 'reset') {
      if (!p) return json({ ok: false, reason: 'code' });
      if (!b.password || String(b.password).length < 6) return json({ ok: false, reason: 'short' });
      const { data: ok } = await admin.rpc('recovery_check', { p_user: p.id, p_hash: await sha(String(b.code || '').trim() + p.id) });
      if (!ok) return json({ ok: false, reason: 'code' });
      const { error } = await admin.auth.admin.updateUserById(p.id, { password: String(b.password) });
      return error ? json({ ok: false, reason: 'error' }) : json({ ok: true });
    }
    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
