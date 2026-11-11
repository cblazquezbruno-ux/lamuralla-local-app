import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

const MES = ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'];
const fdate = (s: string) => { const [y, m, d] = s.split('-').map(Number); return `${d} ${MES[m - 1]}`; };

// Lo llama la base de datos cuando entra un mensaje, un evento o una reserva, y manda el aviso al móvil.
Deno.serve(async (req) => {
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: cfg } = await admin.rpc('push_config');
  if (!cfg || req.headers.get('x-notify-secret') !== cfg.notify_secret) return new Response('no', { status: 401 });
  webpush.setVapidDetails(cfg.vapid_subject, cfg.vapid_public, cfg.vapid_private);

  const { table, record: r } = await req.json();
  let to: string[] = [], title = 'La Muralla', body = '', url = './';
  const admins = async () => ((await admin.from('profiles').select('id').eq('role', 'admin')).data || []).map((x: any) => x.id);
  const biz = async (id: string) => (await admin.from('profiles').select('business').eq('id', id).maybeSingle()).data?.business || 'Un local';

  if (table === 'messages') {
    if (r.from_team) { to = [r.client_id]; title = `${r.who || 'La Muralla'} · La Muralla`; url = './#chat'; }
    else { to = await admins(); title = `💬 ${await biz(r.client_id)}`; url = './#chat'; }
    body = String(r.text || '').slice(0, 160);
  } else if (table === 'events') {
    to = await admins(); title = `🎉 Nuevo evento · ${await biz(r.client_id)}`; body = `${r.title}${r.date ? ' · ' + fdate(r.date) : ''}. Responde con presupuesto.`;
  } else if (table === 'bookings') {
    to = await admins(); title = `🎬 Nueva grabación · ${await biz(r.client_id)}`; body = `${fdate(r.date)} · ${r.slot}`;
  }
  if (!to.length) return new Response('ok');

  const { data: subs } = await admin.from('push_subs').select('*').in('user_id', to);
  const payload = JSON.stringify({ title, body, url });
  let sent = 0;
  await Promise.all((subs || []).map(async (s: any) => {
    try { await webpush.sendNotification(s.sub, payload, { TTL: 86400 }); sent++; }
    catch (e: any) { if (e?.statusCode === 404 || e?.statusCode === 410) await admin.from('push_subs').delete().eq('id', s.id); }
  }));
  return new Response(JSON.stringify({ sent }), { headers: { 'Content-Type': 'application/json' } });
});
