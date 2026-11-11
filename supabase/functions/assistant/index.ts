import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const MES = ['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
const DIA = ['domingo','lunes','martes','miércoles','jueves','viernes','sábado'];
const fd = (s: string) => { const [y, m, d] = s.split('-').map(Number); const dt = new Date(Date.UTC(y, m - 1, d)); return `${DIA[dt.getUTCDay()]} ${d} de ${MES[m - 1]}`; };
const eur = (n: number) => (Math.round(n * 100) / 100).toLocaleString('es-ES', { maximumFractionDigits: 2 }) + ' €';
const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
const todayES = () => new Date(new Date().toLocaleString('en-US', { timeZone: 'Europe/Madrid' }));
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

// Asistente privado: solo lee los datos del propio usuario que pregunta.
// Si existe el secreto ANTHROPIC_API_KEY responde con Claude; si no, con respuestas preparadas usando sus datos.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: u } = await admin.auth.getUser((req.headers.get('Authorization') || '').replace('Bearer ', ''));
    if (!u?.user) return json({ error: 'Inicia sesión' }, 401);
    const uid = u.user.id;
    const { text } = await req.json();
    const q = String(text || '').trim().slice(0, 800);
    if (!q) return json({ error: 'Escribe tu pregunta' }, 400);

    const [{ data: p }, { data: st }] = await Promise.all([
      admin.from('profiles').select('*').eq('id', uid).single(),
      admin.from('settings').select('data').eq('id', 1).single(),
    ]);
    const s = st!.data;
    const today = todayES(); const tIso = iso(today);
    const wm = today.getDate() > 24 ? iso(new Date(today.getFullYear(), today.getMonth() + 1, 1)).slice(0, 7) : tIso.slice(0, 7);
    const lead = Math.ceil(Number(s.changeHours || 48) / 24);
    const leadIso = iso(new Date(today.getFullYear(), today.getMonth(), today.getDate() + lead));
    const [{ data: bks }, { data: ex }, { data: evs }, { data: pays }, { data: av }, { data: taken }, { data: hist }] = await Promise.all([
      admin.from('bookings').select('date,slot,needs,needs_sent,checks').eq('client_id', uid).gte('date', tIso).order('date'),
      admin.from('extras').select('*').eq('client_id', uid).eq('month', wm).maybeSingle(),
      admin.from('events').select('title,status,quote,date,paid').eq('client_id', uid).order('created_at', { ascending: false }).limit(5),
      admin.from('payments').select('date,concept,base,iva').eq('client_id', uid).order('date', { ascending: false }).limit(5),
      admin.from('availability').select('date,slots').gte('date', leadIso).order('date').limit(40),
      admin.from('bookings').select('date,slot').gte('date', leadIso),
      admin.from('assistant_messages').select('role,text').eq('user_id', uid).order('created_at', { ascending: false }).limit(10),
    ]);
    const isAdmin = p?.role === 'admin';
    const pack = s.packs.find((x: any) => x.id === p?.pack) || s.packs[0];
    const packName = p?.custom_pack?.name || pack.name;
    const feats: string[] = p?.custom_pack?.features?.length ? p.custom_pack.features : pack.features;
    const iva = p?.iva_pct !== null && p?.iva_pct !== undefined ? Number(p.iva_pct) : Number(s.iva);
    const dayP = p?.extra_day_price ?? s.extraDay;
    const free = (av || []).map((a: any) => ({ date: a.date, slots: a.slots.filter((sl: string) => !(taken || []).some((t: any) => t.date === a.date && t.slot === sl)) })).filter((a: any) => a.slots.length).slice(0, 6);
    const nb: any = (bks || [])[0];
    const need: string[] = nb?.needs_sent ? (nb.needs || []) : [];
    const MEET: Record<string, string> = { pendiente: 'aún no ha pedido la reunión de arranque (se pide en Inicio → «Pedir mi reunión»)', solicitada: 'ha pedido la reunión de arranque y el equipo le confirmará día y hora por el chat', confirmada: `reunión de arranque confirmada para ${p?.meeting_at ? new Date(p.meeting_at).toLocaleString('es-ES', { timeZone: 'Europe/Madrid', weekday: 'long', day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' }) : '—'}`, hecha: 'reunión de arranque hecha: ya puede elegir día de rodaje en Inicio' };
    const pend = ex ? Math.max(0, ex.days - ex.paid_days) * Number(ex.day_price) : 0;
    const start = p?.start_date ? new Date(p.start_date) : today;
    const minEnd = new Date(start); minEnd.setMonth(minEnd.getMonth() + Number(s.minMonths || 3));
    const ivaTxt = iva === 0 ? 'sin IVA' : `+ IVA (${iva} %)`;

    const ctx = isAdmin ? `Usuario: miembro del equipo de La Muralla.` : [
      `Negocio: ${p.business}. Contacto: ${p.contact}. Sector: ${p.sector}.`,
      `Paquete: ${packName}, ${eur(Number(p.price))} al mes ${ivaTxt}. Incluye: ${feats.join('; ')}.`,
      `Estado: ${p.status}${p.cancel_requested_at ? ' (ha pedido la baja)' : ''}. Cliente desde ${p.start_date}. Permanencia mínima hasta ${iso(minEnd)}. Baja con ${s.noticeDays} días de aviso.`,
      `Proceso: 1) reunión de arranque, 2) elegir día de rodaje (solo cuando la reunión está hecha), 3) el equipo le envía qué necesita preparar, 4) contenido en la pestaña Contenido (calendario, guiones y «Envíanos archivos»). Situación: ${MEET[p.meeting_status] || ''}.`,
      `Próximas grabaciones: ${(bks || []).length ? bks!.map((b: any) => fd(b.date) + ' ' + b.slot).join('; ') : 'ninguna reservada'}.`,
      `Días libres para reservar: ${free.length ? free.map((f: any) => fd(f.date) + ' (' + f.slots.join(', ') + ')').join('; ') : 'ninguno ahora mismo'}.`,
      `Días extra este mes: ${ex?.days || 0} (precio ${eur(Number(dayP))} ${ivaTxt}). Extras pendientes de pago: ${eur(pend)}.`,
      `Eventos: ${(evs || []).map((e: any) => e.title + ' (' + e.status + (e.quote ? ', ' + eur(Number(e.quote)) : '') + ')').join('; ') || 'ninguno'}.`,
      `Últimos pagos: ${(pays || []).map((x: any) => x.date + ' ' + x.concept + ' ' + eur(Number(x.base))).join('; ') || 'ninguno'}.`,
      `Qué necesitamos para su próximo rodaje: ${need.length ? need.join('; ') : 'el equipo aún no lo ha enviado (lo enviará tras confirmar el rodaje)'}.`,
      `Normas: cambio de día hasta ${s.changeHours} h antes desde el calendario de Inicio; eventos con presupuesto en ${s.eventHours} h; el calendario de publicaciones está en la pestaña Contenido; la cuota se cobra sola cada mes por PayPal; también puede pagar por transferencia o Bizum desde Pagos → «Pagar por transferencia, Bizum u otra forma»; las facturas llegan solas a Pagos y a su email; los extras se pagan desde Pagos.`,
    ].join('\n');

    let reply = '';
    const key = Deno.env.get('ANTHROPIC_API_KEY');
    if (key) {
      const msgs = [...(hist || [])].reverse().map((m: any) => ({ role: m.role, content: m.text }));
      msgs.push({ role: 'user', content: q });
      const r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST', headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
        body: JSON.stringify({ model: Deno.env.get('ASSISTANT_MODEL') || 'claude-haiku-5-5', max_tokens: 500,
          system: `Eres el asistente de la app de La Muralla Local (agencia de contenido para negocios locales en Talavera de la Reina). Hablas en español de España, cercano y breve (máximo 4 frases o una lista corta). Responde SOLO con los datos de este cliente que tienes abajo y las normas; si no lo sabes, dilo y sugiere escribir al equipo en la pestaña "Equipo" del chat. No inventes precios, fechas ni promesas. No hagas cambios: explica dónde se hacen en la app.\n\nDATOS DEL CLIENTE (privados):\n${ctx}\nHoy es ${fd(tIso)}.`,
          messages: msgs }),
      });
      if (r.ok) { const j = await r.json(); reply = (j.content || []).map((c: any) => c.text || '').join('').trim(); }
    }

    if (!reply) {
      const n = norm(q);
      const has = (...w: string[]) => w.some((x) => n.includes(x));
      if (isAdmin) reply = 'Soy el asistente de los clientes. Desde el panel del equipo tienes Hoy (tus tareas y la bandeja), Agenda, Clientes y Ajustes.';
      else if (has('hola', 'buenas', 'hey', 'ey')) reply = `¡Hola, ${String(p.contact || '').split(' ')[0]}! Pregúntame lo que quieras: cuándo grabamos, qué preparar, cuánto pagas este mes, cómo añadir un día extra…`;
      else if (has('gracias', 'genial', 'perfecto', 'ok')) reply = '¡A ti! Si necesitas algo más, aquí estoy. Y si prefieres hablar con una persona, ve a la pestaña "Equipo".';
      else if (has('reunion', 'reunirnos', 'arranque')) reply = 'Tu situación: ' + (MEET[p.meeting_status] || '') + '.';
      else if (has('archivo', 'enviar foto', 'mandar foto', 'pdf', 'subir')) reply = 'Puedes mandarnos fotos, PDF o lo que quieras en Contenido → «Envíanos archivos». Solo lo ve el equipo.';
      else if (has('cambiar', 'mover', 'otro dia', 'otra fecha')) reply = `Puedes cambiar tu día hasta ${s.changeHours} h antes: en Inicio toca un día libre del calendario, elige la franja y pulsa "Cambiar mi grabación".` + (free.length ? ` Ahora mismo hay libre: ${free.slice(0, 3).map((f: any) => fd(f.date)).join(', ')}.` : '');
      else if (has('prepar', 'necesit', 'llevar', 'tener listo', 'guion', 'guiones')) reply = need.length ? `Para tu rodaje necesitamos:\n• ${need.join('\n• ')}\nLo tienes en Inicio para ir marcándolo. Los guiones están en Contenido → Guiones.` : 'Todavía no tienes que preparar nada: cuando confirmemos tu rodaje te enviaremos aquí la lista. Los guiones aparecerán en Contenido → Guiones.';
      else if (has('dia extra', 'mas contenido', 'otro dia de grab', 'extra')) reply = `Un día extra de grabación cuesta ${eur(Number(dayP))} ${ivaTxt}. En Pagos pulsa + en "Día extra de rodaje" y luego elige el día en el calendario de Inicio. Este mes llevas ${ex?.days || 0}.`;
      else if (has('evento', 'fiesta', 'inauguracion', 'cata')) reply = `En Inicio pulsa "¿Tienes un evento?", cuéntanos qué es y la fecha. En menos de ${s.eventHours} h te confirmamos si podemos ir y el presupuesto, que aceptas desde la app.`;
      else if (has('baja', 'cancelar', 'darme de baja', 'permanencia', 'contrato')) reply = `Tu permanencia mínima termina el ${fd(iso(minEnd))}. La baja se pide con ${s.noticeDays} días de antelación desde Perfil → "Contrato y baja".` + (p.cancel_requested_at ? ' Ya nos la pediste: el equipo te escribirá para confirmarla.' : '');
      else if (has('pago', 'pagar', 'cobr', 'cuota', 'cuanto', 'precio', 'factura', 'iva', 'debo')) reply = `Tu ${packName} cuesta ${eur(Number(p.price))} al mes ${ivaTxt} y se cobra solo cada mes por PayPal.` + (pend > 0 ? ` Tienes ${eur(pend)} de extras pendientes; puedes pagarlos en Pagos.` : ' No tienes nada pendiente.') + ' Tus facturas llegan solas a Pagos y a tu email. También puedes pagar por transferencia o Bizum desde Pagos.';
      else if (has('cuando', 'proxim', 'grabacion', 'grabar', 'rodaje', 'venis', 'vienen', 'fecha', 'dia')) reply = (bks || []).length ? `Tu próxima grabación es el ${fd(bks![0].date)}, de ${bks![0].slot}.` + ((bks || []).length > 1 ? ` Después: ${bks!.slice(1).map((b: any) => fd(b.date)).join(', ')}.` : '') : `Aún no tienes día reservado.` + (p.meeting_status !== 'hecha' ? ' Primero hacemos la reunión de arranque: ' + (MEET[p.meeting_status] || '') + '.' : '') + (p.meeting_status === 'hecha' && free.length ? ` Hay libre: ${free.slice(0, 3).map((f: any) => fd(f.date) + ' (' + f.slots[0] + ')').join(', ')}. Resérvalo en el calendario de Inicio.` : ' En cuanto abramos días te aparecerán en el calendario.');
      else if (has('pack', 'incluye', 'servicio', 'completo', 'asistente ia', 'telefono')) reply = `Tu ${packName} incluye:\n• ${feats.join('\n• ')}` + (p.pack !== 'completo' && !p.custom_pack ? `\nSi quieres que tu teléfono conteste solo, mira el Pack Completo en Inicio.` : '');
      else if (has('contrasena', 'instagram', 'acceso', 'tiktok', 'meta')) reply = 'Tus accesos a redes están en Perfil → "Acceso a tus redes". Lo más cómodo es invitarnos como socios en Meta Business, sin compartir contraseña. Si la cambias, actualízala ahí.';
      else if (has('publica', 'contenido', 'calendario', 'aprobar', 'post', 'reel')) reply = 'Tu calendario de publicaciones está en la pestaña Contenido: cada día verás qué se publica (reel, carrusel…) y cuál en concreto. Puedes aprobarlo o pedir cambios ahí mismo.';
      else reply = 'No tengo esa respuesta, pero te puedo ayudar con: cuándo grabamos, cambiar el día, qué preparar, pagos, días extra, eventos o la baja. Para cualquier otra cosa, escribe al equipo en la pestaña "Equipo".';
    }

    await admin.from('assistant_messages').insert([{ user_id: uid, role: 'user', text: q }, { user_id: uid, role: 'assistant', text: reply }]);
    return json({ reply, ai: !!key });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
