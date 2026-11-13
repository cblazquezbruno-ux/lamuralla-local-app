import { createClient } from 'npm:@supabase/supabase-js@2';
import { PDFDocument, StandardFonts, rgb } from 'npm:pdf-lib@1.17.1';

// Genera el PDF del contrato firmado (texto + firma + datos de la firma) y lo guarda en la app.
// La llama la base de datos al firmar (x-notify-secret) o el equipo/cliente para regenerarlo.
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const clean = (s: unknown) => String(s ?? '').replace(/[^\x20-\x7E -ÿ€‘’“”–—…•›‹]/g, '');

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));
    const { data: cfg } = await admin.rpc('push_config');
    const fromDb = !!cfg && req.headers.get('x-notify-secret') === cfg.notify_secret;
    const { data: k } = await admin.from('contracts').select('*').eq('id', b.contract_id).single();
    if (!k) return json({ error: 'Contrato no encontrado' }, 404);
    if (!fromDb) {
      const { data: u } = await admin.auth.getUser((req.headers.get('Authorization') || '').replace('Bearer ', ''));
      if (!u?.user) return json({ error: 'Inicia sesión' }, 401);
      const { data: me } = await admin.from('profiles').select('role').eq('id', u.user.id).single();
      if (me?.role !== 'admin' && u.user.id !== k.client_id) return json({ error: 'No permitido' }, 403);
    }
    const { data: st } = await admin.from('settings').select('data').eq('id', 1).single();
    const inv = st?.data?.invoice || {};

    const pdf = await PDFDocument.create();
    const f = await pdf.embedFont(StandardFonts.Helvetica), fb = await pdf.embedFont(StandardFonts.HelveticaBold);
    const W = 595.28, H = 841.89, M = 56, ink = rgb(0.08, 0.08, 0.09), grey = rgb(0.42, 0.43, 0.46);
    let page = pdf.addPage([W, H]); let y = H - 60;
    const newPage = () => { page = pdf.addPage([W, H]); y = H - 60; };
    const wrap = (s: string, size: number, font: any, max: number) => {
      const out: string[] = []; let cur = '';
      for (const w of clean(s).split(' ')) { const n = cur ? cur + ' ' + w : w; if (font.widthOfTextAtSize(n, size) > max && cur) { out.push(cur); cur = w; } else cur = n; }
      out.push(cur); return out;
    };
    if (inv.logo) { try { const r = await fetch(inv.logo); const bb = new Uint8Array(await r.arrayBuffer()); const img = bb[0] === 0x89 ? await pdf.embedPng(bb) : await pdf.embedJpg(bb); const h = 26, w = img.width * h / img.height; page.drawImage(img, { x: M, y: y - 6, width: w, height: h }); y -= 44; } catch (_) { /* sin logo */ } }
    for (const raw of String(k.text).split('\n')) {
      const line = raw.trimEnd();
      if (!line) { y -= 8; continue; }
      const head = /^\d+\.\s/.test(line) || line.startsWith('CONTRATO');
      const size = line.startsWith('CONTRATO') ? 12.5 : 9.8, font = head ? fb : f;
      for (const l of wrap(line, size, font, W - 2 * M)) { if (y < 70) newPage(); page.drawText(l, { x: M, y, size, font, color: ink }); y -= size * 1.45; }
    }
    // firma
    if (y < 230) newPage();
    y -= 18; page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.6, color: rgb(0.85, 0.85, 0.86) }); y -= 22;
    page.drawText('FIRMA DEL CLIENTE', { x: M, y, size: 8, font: fb, color: grey }); y -= 8;
    const { data: sig } = await admin.storage.from('files').download(k.signature_path);
    if (sig) { const img = await pdf.embedPng(new Uint8Array(await sig.arrayBuffer())); const w = 200, h = w * img.height / img.width; page.drawImage(img, { x: M, y: y - h, width: w, height: h }); y -= h + 10; }
    const when = new Date(k.signed_at).toLocaleString('es-ES', { timeZone: 'Europe/Madrid' });
    for (const l of [`${k.name}${k.nif ? ' · NIF ' + k.nif : ''}`, `Firmado electrónicamente desde la app La Muralla Local el ${when}`, `Huella del texto (SHA-256): ${k.text_hash}`, `Dispositivo: ${String(k.user_agent || '').slice(0, 110)}`]) {
      for (const w of wrap(l, 8.5, f, W - 2 * M)) { page.drawText(w, { x: M, y, size: 8.5, font: f, color: grey }); y -= 12; }
    }
    const pages = pdf.getPages(); pages.forEach((p, i) => p.drawText(`La Muralla Local · Contrato de ${clean(k.name)} · ${i + 1}/${pages.length}`, { x: M, y: 30, size: 7.5, font: f, color: grey }));
    const bytes = await pdf.save();
    const path = `${k.client_id}/contrato/contrato-${String(k.signed_at).slice(0, 10)}-${k.id.slice(0, 6)}.pdf`;
    const up = await admin.storage.from('files').upload(path, bytes, { contentType: 'application/pdf', upsert: true });
    if (up.error) return json({ error: up.error.message }, 500);
    await admin.from('contracts').update({ pdf_path: path }).eq('id', k.id);
    return json({ ok: true, path });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
