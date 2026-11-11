import { createClient } from 'npm:@supabase/supabase-js@2';
import { PDFDocument, StandardFonts, rgb } from 'npm:pdf-lib@1.17.1';

// Genera la factura en PDF de un pago, la guarda, la deja en la app del cliente y (si hay RESEND_API_KEY) se la manda por email.
// La llama la base de datos al marcar un pago como «pagado» (x-notify-secret) o el equipo desde la app (reenviar / vista previa).
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const eur = (n: number) => (Math.round(n * 100) / 100).toLocaleString('es-ES', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €';
const fdate = (s: string) => s.slice(0, 10).split('-').reverse().join('/');
const hex = (h: string) => { const m = /^#?([0-9a-f]{6})$/i.exec(h || ''); const v = m ? parseInt(m[1], 16) : 0xDA7F2C; return rgb(((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255); };
// Helvetica estándar solo admite WinAnsi: quitamos lo que no se puede dibujar (emojis, etc.)
const clean = (s: unknown) => String(s ?? '').replace(/[^\x20-\x7E -ÿ€‘’“”–—…•]/g, '').trim();

type Inv = { number: string; date: string; concept: string; base: number; iva_pct: number; iva: number; total: number; method?: string; client: Record<string, string>; issuer: Record<string, string> };

async function buildPdf(inv: Inv, logoUrl?: string) {
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595.28, 841.89]);
  const f = await pdf.embedFont(StandardFonts.Helvetica), fb = await pdf.embedFont(StandardFonts.HelveticaBold);
  const ink = rgb(0.07, 0.07, 0.08), grey = rgb(0.42, 0.43, 0.46), line = rgb(0.88, 0.88, 0.89), acc = hex(inv.issuer.color);
  const W = 595.28, M = 50;
  const txt = (s: string, x: number, y: number, o: { size?: number; bold?: boolean; color?: any; right?: boolean } = {}) => {
    const font = o.bold ? fb : f, size = o.size || 10, t = clean(s);
    const w = font.widthOfTextAtSize(t, size);
    page.drawText(t, { x: o.right ? x - w : x, y, size, font, color: o.color || ink });
  };
  const wrap = (s: string, max: number, size = 10, font = f) => {
    const out: string[] = []; let cur = '';
    for (const w of clean(s).split(/\s+/)) { const n = cur ? cur + ' ' + w : w; if (font.widthOfTextAtSize(n, size) > max && cur) { out.push(cur); cur = w; } else cur = n; }
    if (cur) out.push(cur); return out;
  };

  page.drawRectangle({ x: 0, y: 841.89 - 6, width: W, height: 6, color: acc });
  let top = 841.89 - 60;
  let drewLogo = false;
  if (logoUrl) {
    try {
      const r = await fetch(logoUrl); const b = new Uint8Array(await r.arrayBuffer());
      const img = (b[0] === 0x89) ? await pdf.embedPng(b) : await pdf.embedJpg(b);
      const h = 34, w = Math.min(190, img.width * h / img.height);
      page.drawImage(img, { x: M, y: top - h + 12, width: w, height: w * img.height / img.width });
      drewLogo = true;
    } catch (_) { /* sin logo */ }
  }
  if (!drewLogo) txt(inv.issuer.name || 'La Muralla', M, top - 8, { size: 18, bold: true });
  txt('FACTURA', W - M, top, { size: 22, bold: true, right: true });
  txt('Nº ' + inv.number, W - M, top - 20, { size: 11, right: true, color: grey });
  txt('Fecha: ' + fdate(inv.date), W - M, top - 34, { size: 10, right: true, color: grey });

  // Emisor y cliente
  top -= 90;
  const block = (title: string, rows: string[], x: number) => {
    txt(title, x, top, { size: 8, bold: true, color: acc });
    let y = top - 16; rows.filter(Boolean).forEach((r, i) => { txt(r, x, y, { size: i === 0 ? 11 : 9.5, bold: i === 0, color: i === 0 ? ink : grey }); y -= 14; });
  };
  const is = inv.issuer, c = inv.client;
  block('EMISOR', [is.name, is.nif ? 'NIF: ' + is.nif : '', is.address, is.city, is.email, is.phone], M);
  block('CLIENTE', [c.name, c.nif ? 'NIF: ' + c.nif : '', c.address, c.city, c.email], W / 2 + 10);

  // Tabla
  top -= 120;
  page.drawRectangle({ x: M, y: top - 8, width: W - 2 * M, height: 26, color: rgb(0.96, 0.96, 0.965) });
  const cols = [M + 10, 360, 420, W - M - 10];
  txt('CONCEPTO', cols[0], top, { size: 8, bold: true, color: grey });
  txt('BASE', cols[1], top, { size: 8, bold: true, color: grey, right: true });
  txt('IVA', cols[2], top, { size: 8, bold: true, color: grey, right: true });
  txt('TOTAL', cols[3], top, { size: 8, bold: true, color: grey, right: true });
  top -= 32;
  const lines = wrap(inv.concept, 270, 10.5);
  lines.forEach((l, i) => txt(l, cols[0], top - i * 14, { size: 10.5, bold: i === 0 }));
  txt(eur(inv.base), cols[1], top, { size: 10.5, right: true });
  txt(inv.iva_pct + ' %', cols[2], top, { size: 10.5, right: true });
  txt(eur(inv.total), cols[3], top, { size: 10.5, right: true, bold: true });
  top -= Math.max(1, lines.length) * 14 + 10;
  page.drawLine({ start: { x: M, y: top }, end: { x: W - M, y: top }, thickness: 0.8, color: line });

  // Totales
  top -= 26;
  const tx = 330;
  txt('Base imponible', tx, top, { size: 10, color: grey }); txt(eur(inv.base), W - M - 10, top, { size: 10, right: true });
  top -= 18;
  txt(inv.iva_pct ? `IVA (${inv.iva_pct} %)` : 'IVA', tx, top, { size: 10, color: grey }); txt(eur(inv.iva), W - M - 10, top, { size: 10, right: true });
  top -= 16;
  page.drawRectangle({ x: tx - 12, y: top - 22, width: W - M - tx + 12, height: 34, color: acc });
  txt('TOTAL', tx, top - 10, { size: 11, bold: true, color: rgb(1, 1, 1) });
  txt(eur(inv.total), W - M - 10, top - 10, { size: 14, bold: true, color: rgb(1, 1, 1), right: true });

  // Pago y notas
  top -= 70;
  const info: string[] = [];
  if (inv.method) info.push('Forma de pago: ' + inv.method);
  if (is.iban) info.push('IBAN: ' + is.iban);
  if (!inv.iva_pct) info.push('Operación sin IVA.');
  if (is.notes) info.push(...String(is.notes).split('\n'));
  info.forEach(l => { wrap(l, W - 2 * M, 9.5).forEach(w => { txt(w, M, top, { size: 9.5, color: grey }); top -= 14; }); });

  // Pie
  if (is.footer) wrap(is.footer, W - 2 * M, 9).forEach((w, i) => txt(w, M, 60 - i * 12, { size: 9, color: grey }));
  txt('La Muralla Local · Labs · Studio', W - M, 36, { size: 8, color: grey, right: true });
  return await pdf.save();
}

const METHOD: Record<string, string> = { paypal: 'PayPal', prueba: 'Pago de prueba', manual: 'Acordado con el equipo', transferencia: 'Transferencia bancaria', bizum: 'Bizum', efectivo: 'Efectivo', tarjeta: 'Tarjeta' };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));
    const { data: cfg } = await admin.rpc('push_config');
    let teamUser: string | null = null;
    const fromDb = !!cfg && req.headers.get('x-notify-secret') === cfg.notify_secret;
    if (!fromDb) {
      const { data: u } = await admin.auth.getUser((req.headers.get('Authorization') || '').replace('Bearer ', ''));
      if (!u?.user) return json({ error: 'Inicia sesión' }, 401);
      const { data: me } = await admin.from('profiles').select('role').eq('id', u.user.id).single();
      if (me?.role !== 'admin') return json({ error: 'Solo el equipo' }, 403);
      teamUser = u.user.id;
    }
    const { data: st } = await admin.from('settings').select('data').eq('id', 1).single();
    const issuer = { name: 'La Muralla Project', color: '#DA7F2C', series: 'LM', ...(st?.data?.invoice || {}) };
    const tpl = b.template ? { ...issuer, ...b.template } : issuer;

    // Vista previa de la factura tipo (no guarda nada)
    if (b.action === 'preview') {
      const { data: num } = await admin.rpc('invoice_preview_number');
      const bytes = await buildPdf({ number: num || 'LM-0000', date: new Date().toISOString(), concept: 'Pack Imagen · Noviembre (ejemplo)', base: 390, iva_pct: 21, iva: 81.9, total: 471.9, method: 'Transferencia bancaria',
        client: { name: 'Bar La Plaza S.L.', nif: 'B00000000', address: 'Plaza del Pan, 1', city: '45600 Talavera de la Reina', email: 'cliente@ejemplo.es' }, issuer: tpl }, tpl.logo);
      return new Response(bytes, { headers: { ...cors, 'Content-Type': 'application/pdf' } });
    }

    const pid = b.payment_id;
    if (!pid) return json({ error: 'Falta el pago' }, 400);
    const { data: pay } = await admin.from('payments').select('*').eq('id', pid).single();
    if (!pay) return json({ error: 'Pago no encontrado' }, 404);
    if (pay.status !== 'pagado') return json({ error: 'El pago no está confirmado' }, 400);
    const { data: c } = await admin.from('profiles').select('*').eq('id', pay.client_id).single();
    if (!c) return json({ error: 'Cliente no encontrado' }, 404);

    let { data: inv } = await admin.from('invoices').select('*').eq('payment_id', pid).maybeSingle();
    const bill = c.billing || {};
    const client = { name: bill.name || c.business || c.contact || '', nif: bill.nif || '', address: bill.address || '', city: bill.city || '', email: bill.email || c.email || '' };
    if (!inv) {
      const base = Number(pay.base) || 0;
      const ivaPct = pay.iva !== null && pay.iva !== undefined ? Number(pay.iva) : (c.iva_pct !== null && c.iva_pct !== undefined ? Number(c.iva_pct) : Number(st?.data?.iva ?? 21));
      const iva = Math.round(base * ivaPct) / 100;
      const { data: number, error: ne } = await admin.rpc('next_invoice_number', { p_series: issuer.series || 'LM' });
      if (ne) return json({ error: ne.message }, 500);
      const row = { client_id: c.id, payment_id: pid, number, date: pay.date || new Date().toISOString().slice(0, 10), concept: pay.concept, base, iva_pct: ivaPct, iva, total: Math.round((base + iva) * 100) / 100, client_data: client, issuer };
      const ins = await admin.from('invoices').insert(row).select().single();
      if (ins.error) return json({ error: ins.error.message }, 500);
      inv = ins.data;
    }
    const bytes = await buildPdf({ number: inv.number, date: inv.date, concept: inv.concept, base: Number(inv.base), iva_pct: Number(inv.iva_pct), iva: Number(inv.iva), total: Number(inv.total), method: METHOD[pay.method] || pay.method, client: inv.client_data || client, issuer: inv.issuer || issuer }, (inv.issuer || issuer).logo);
    const path = `${c.id}/facturas/${inv.number}.pdf`;
    const up = await admin.storage.from('files').upload(path, bytes, { contentType: 'application/pdf', upsert: true });
    if (up.error) return json({ error: up.error.message }, 500);
    await admin.from('invoices').update({ pdf_path: path }).eq('id', inv.id);

    // Email (si está configurado)
    let emailed = false, emailNote = 'email no configurado';
    const key = Deno.env.get('RESEND_API_KEY');
    const to = client.email;
    if (key && to && (!inv.emailed_at || b.action === 'resend')) {
      let bin = ''; bytes.forEach((x: number) => bin += String.fromCharCode(x));
      const r = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: Deno.env.get('INVOICE_FROM') || `${issuer.name} <facturas@lamurallaproject.es>`, to: [to], reply_to: issuer.email || undefined,
          subject: `Factura ${inv.number} · ${issuer.name}`,
          html: `<p>Hola ${clean(c.contact || '')},</p><p>Te adjuntamos la factura <b>${inv.number}</b> por <b>${eur(Number(inv.total))}</b> (${clean(inv.concept)}).</p><p>También la tienes en la app, en <b>Pagos</b>.</p><p>${clean(issuer.footer || 'Gracias por confiar en La Muralla Local.')}</p>`,
          attachments: [{ filename: `Factura-${inv.number}.pdf`, content: btoa(bin) }] }) });
      emailed = r.ok; emailNote = r.ok ? 'enviada por email' : 'el email ha fallado: ' + (await r.text()).slice(0, 120);
      if (r.ok) await admin.from('invoices').update({ emailed_at: new Date().toISOString() }).eq('id', inv.id);
    } else if (!to) emailNote = 'el cliente no tiene email';
    else if (inv.emailed_at && b.action !== 'resend') emailNote = 'ya se había enviado';

    if (b.action !== 'resend') {
      await admin.from('messages').insert({ client_id: c.id, sender_id: teamUser || c.id, from_team: true, who: 'La Muralla', text: `Tu factura ${inv.number} (${eur(Number(inv.total))}) ya está en la app, en Pagos.${emailed ? ' También te la hemos mandado por email.' : ''}` });
    }
    return json({ ok: true, number: inv.number, path, emailed, email: emailNote });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
