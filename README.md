# La Muralla Local · App de clientes

App web instalable en el móvil (PWA) para los locales de **La Muralla Local** y para el equipo.

- **App en marcha:** https://cblazquezbruno-ux.github.io/lamuralla-local-app/
- **Base de datos y servidor:** Supabase, proyecto `la-muralla-local` (ref. `ugwzbcrvamfpxpcfldag`, servidores en París)
- **Pagos:** PayPal (suscripción mensual + pagos sueltos de extras). Ahora mismo en **modo prueba**.

## Qué hace

**Local (cliente)** — 5 pestañas: Inicio · Contenido · Pagos · Chat · Perfil.
- Camino en 4 pasos: **Reunión → Rodaje → Preparación → Contenido**.
- Paso 1: pide la reunión de arranque (día, franja y dónde). El equipo la confirma y la marca como hecha.
- Paso 2: solo entonces puede reservar rodaje. Solo ve días y horas libres; la primera reserva se queda la hora y desaparece para los demás (lo garantiza la base de datos).
- Paso 3: el equipo le envía «qué necesitamos» para ese rodaje y él lo va marcando.
- Contenido: calendario de publicaciones (qué día, tipo y cuál en concreto, con archivos), guiones (texto o archivos) y «Envíanos archivos» (fotos, PDF…).
- Pagos: mes en curso, días extra, eventos, PayPal/tarjeta o **transferencia/Bizum** (avisa con un botón) y sus **facturas** en PDF.
- Perfil con su **logo**, datos de facturación, objetivos, accesos, contrato y baja. Chat privado y asistente.

**Equipo** — Hoy · Agenda · Clientes · Contabilidad · Chat · Ajustes. Cada miembro entra con su cuenta.
- Hoy: tus tareas del día (con tiempos, se tachan al hacerlas), las de cada compañero o de todos, y la bandeja (reuniones pedidas, rodajes sin lista, pagos por confirmar, eventos, bajas, archivos nuevos).
- Agenda: abrir días y franjas, reuniones y rodajes próximos.
- Ficha de cada cliente: Resumen (reunión y listas de rodaje) · Contenido (calendario, guiones, archivos del cliente) · Tareas · Pagos (confirmar pagos, facturas, registrar pagos).
- **Contabilidad La Muralla**: ingresos y gastos de Labs, Local, Studio y General (cualquiera del equipo apunta, todos lo ven), con ticket adjunto, beneficio por mes/año y por área, IVA cobrado/pagado y descarga en CSV para la gestoría. Los pagos cobrados desde la app entran solos como ingresos de Local.
- Ajustes: **factura tipo** (datos, logo, color, serie, notas) con vista previa, datos de pago para transferencia/Bizum, precios, campaña, condiciones, PayPal, cuentas del equipo, copias.

**Facturas automáticas:** cuando un pago queda como «pagado» (PayPal, alta, o el equipo confirma una transferencia) la base de datos llama a la función `invoice`, que numera (`LM-2026-0001`…), genera el PDF con la plantilla, lo guarda en la app del cliente y, si está configurado `RESEND_API_KEY`, se lo envía por email.
> Verifactu: la obligación del software de facturación verificable empieza en 2027 (sociedades el 1 de enero, autónomos el 1 de julio, según el RDL 15/2025). Antes de esa fecha habrá que conectar la facturación a un sistema certificado o adaptarla.

## Estructura del repositorio

```
index.html              ← la app ya montada (es lo que publica GitHub Pages)
sw.js                   ← service worker: avisos push y arranque rápido
manifest.webmanifest    ← para instalarla en el móvil
icon-192.png, icon-512.png, apple-touch-icon.png
source/
  app.src.html          ← CÓDIGO FUENTE de la app (HTML + CSS + JS)
  base.css              ← estilos base
  assets/               ← fuente Archivo, logo, fotos del equipo
  build.py              ← genera index.html a partir de app.src.html
supabase/
  migrations/           ← estructura de la base de datos, en orden
  seed.sql              ← ajustes iniciales (precios, listas, condiciones)
  functions/            ← funciones del servidor (Deno / TypeScript)
    signup/             ← alta de clientes (con pago) y altas manuales del equipo
    pay-extras/         ← cobro de días extra y eventos (verifica el pago en PayPal)
    paypal-webhook/     ← cuotas mensuales, impagos y cancelaciones que avisa PayPal
    team/               ← acciones del equipo: crear cuentas, contraseñas, bajas, borrar
    assistant/          ← asistente privado de cada cliente
    notify/             ← avisos push al móvil
    invoice/            ← genera la factura en PDF, la guarda y la envía por email
  manual/               ← pasos que se hacen a mano una vez (avisos push, primer admin)
  config.toml
.github/workflows/mantener-activa.yml  ← consulta cada 2 días para que Supabase gratis no se pause
```

## Cambiar la app

1. Edita `source/app.src.html` (o `source/base.css`).
2. Genera la app: `python3 source/build.py` → actualiza `index.html`.
3. Si cambias algo importante, sube la versión de caché en `sw.js` (`const C='lml-vX'`) para que los móviles cojan la nueva.
4. Sube los cambios a las ramas `main` y `gh-pages` (Pages publica `gh-pages`):
   ```bash
   git add -A && git commit -m "Cambio" && git push origin main && git push origin main:gh-pages
   ```

La conexión a Supabase está arriba del todo del script, en `CFG` (`url`, `key` pública y clave pública de avisos `vapid`). La clave que aparece es la **publicable**: es pública por diseño. La seguridad está en las reglas de la base de datos (RLS), no en ocultarla.

## Servidor (Supabase)

Con la [CLI de Supabase](https://supabase.com/docs/guides/cli):

```bash
supabase link --project-ref ugwzbcrvamfpxpcfldag
supabase functions deploy signup --no-verify-jwt
supabase functions deploy notify --no-verify-jwt
supabase functions deploy paypal-webhook --no-verify-jwt
supabase functions deploy invoice --no-verify-jwt
supabase functions deploy pay-extras
supabase functions deploy team
supabase functions deploy assistant
```

Para montar un proyecto **nuevo** desde cero: aplica `supabase/migrations/` en orden, luego `supabase/seed.sql`, luego `supabase/manual/01_avisos_push.sql` (con tus claves) y crea el primer admin con `supabase/manual/02_primer_admin.md`.

### Secretos (Supabase › Edge Functions › Secrets)

| Secreto | Para qué |
|---|---|
| `PAYPAL_CLIENT_ID` | Client ID de la app de PayPal |
| `PAYPAL_SECRET` | Secret de la app de PayPal |
| `PAYPAL_WEBHOOK_ID` | ID del webhook de PayPal (verifica que los avisos vienen de PayPal) |
| `ANTHROPIC_API_KEY` | (opcional) para que el asistente entienda cualquier pregunta con Claude |
| `ASSISTANT_MODEL` | (opcional) modelo de Claude; por defecto `claude-haiku-5-5` |
| `RESEND_API_KEY` | (opcional) para mandar las facturas por email con [Resend](https://resend.com) |
| `INVOICE_FROM` | (opcional) remitente, p. ej. `La Muralla <facturas@lamurallaproject.es>` (el dominio debe estar verificado en Resend) |

Los secretos **nunca** van en este repositorio.

## Activar PayPal (cobro real)

1. En https://developer.paypal.com/dashboard/applications/live crea una app → copia **Client ID** y **Secret**.
2. En https://www.paypal.com/billing/plans crea 2 planes de suscripción mensual: **Pack Imagen** (390 € + IVA) y **Pack Completo** (590 € + IVA; el alta del asistente como cuota de alta del plan) → copia los IDs `P-...`.
3. En la app de PayPal, sección *Webhooks*, añade `https://ugwzbcrvamfpxpcfldag.supabase.co/functions/v1/paypal-webhook` con los eventos
   `PAYMENT.SALE.COMPLETED`, `BILLING.SUBSCRIPTION.CANCELLED`, `BILLING.SUBSCRIPTION.SUSPENDED`, `BILLING.SUBSCRIPTION.PAYMENT.FAILED` → copia su **Webhook ID**.
4. Mete los 3 secretos en https://supabase.com/dashboard/project/ugwzbcrvamfpxpcfldag/functions/secrets
5. En la app (cuenta de equipo) › Ajustes › PayPal: pega el Client ID y los IDs de los planes, elige **Real** y desactiva **Modo prueba**.

## Seguridad

- Cada local solo ve sus datos (RLS en todas las tablas). Los campos sensibles (precio, pack, estado, IVA…) solo los cambia el equipo.
- Las contraseñas de Instagram se guardan cifradas en Supabase Vault y solo las lee el equipo.
- El asistente solo consulta los datos del cliente que pregunta y su conversación es privada.
- Las altas solo se pueden hacer desde la app (registro externo bloqueado).
- Copia de seguridad automática cada noche (14 días) + descarga manual desde Ajustes.

## Cuentas

Equipo: `JoseP`, `BrunoB` y `JesusP` (contraseñas aparte; cambiadlas en Ajustes › Equipo). Los clientes se crean desde la portada (alta con pago) o desde Clientes › «Dar de alta un local».
