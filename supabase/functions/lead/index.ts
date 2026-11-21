import { createClient } from 'npm:@supabase/supabase-js@2';

// Recibe las solicitudes de plaza de la landing de la campaña (público, con antispam).
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const sha = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))).map((b) => b.toString(16).padStart(2, '0')).join('');
const str = (v: unknown, max: number) => String(v ?? '').replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, max);
const SECT = ['hosteleria', 'salud', 'comercio', 'turismo', 'otro'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405);
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));
    if (b.hp) return json({ ok: true }); // honeypot: los bots rellenan el campo oculto
    if (Number(b.t || 0) && Date.now() - Number(b.t) < 2500) return json({ ok: true }); // enviado en menos de 2,5 s: bot
    const f = {
      business: str(b.business, 80), sector: SECT.includes(b.sector) ? b.sector : 'otro', contact: str(b.contact, 60),
      phone: str(b.phone, 20).replace(/[^\d+ ]/g, ''), email: str(b.email, 120).toLowerCase(), zone: str(b.zone, 120),
      social: str(b.social, 200), need: str(b.need, 400), ref_code: str(b.ref, 20).toUpperCase() || null, source: str(b.src, 60) || null,
    };
    if (f.business.length < 2) return json({ error: 'Escribe el nombre de tu negocio' }, 400);
    if (f.contact.length < 2) return json({ error: 'Escribe tu nombre' }, 400);
    if (f.phone.replace(/\D/g, '').length < 9) return json({ error: 'Revisa el teléfono' }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(f.email)) return json({ error: 'Revisa el email' }, 400);
    if (b.privacy !== true) return json({ error: 'Tienes que aceptar la política de privacidad' }, 400);

    const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || 'x';
    const ipHash = (await sha(ip + '|lml-campana')).slice(0, 32);
    const hourAgo = new Date(Date.now() - 3600e3).toISOString();
    const { count } = await admin.from('leads').select('id', { count: 'exact', head: true }).eq('ip_hash', ipHash).gte('created_at', hourAgo);
    if ((count || 0) >= 4) return json({ error: 'Has enviado varias solicitudes seguidas. Espera un rato o escríbenos por WhatsApp.' }, 429);

    // misma persona otra vez: no duplicamos
    const digits = f.phone.replace(/\D/g, '').slice(-9);
    const { data: prev } = await admin.from('leads').select('id,phone').in('status', ['pendiente', 'aprobada']).order('created_at', { ascending: false }).limit(300);
    const dup = (prev || []).find((x: any) => String(x.phone).replace(/\D/g, '').slice(-9) === digits);
    if (dup) { const upd: Record<string, unknown> = { ...f }; if (!f.ref_code) delete upd.ref_code; await admin.from('leads').update(upd).eq('id', dup.id); return json({ ok: true, again: true }); }

    let referrer: string | null = null;
    if (f.ref_code) { const { data: r } = await admin.from('profiles').select('id').eq('referral_code', f.ref_code).eq('role', 'client').maybeSingle(); referrer = r?.id || null; }
    const { error } = await admin.from('leads').insert({ ...f, referrer, ip_hash: ipHash, user_agent: str(req.headers.get('user-agent'), 200), privacy_at: new Date().toISOString() });
    if (error) return json({ error: 'No hemos podido guardar tu solicitud. Inténtalo otra vez.' }, 500);
    return json({ ok: true });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
