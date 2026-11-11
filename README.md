# La Muralla Local · App de clientes

App web instalable en el móvil (PWA) para los locales de **La Muralla Local** y para el equipo.

- **App en marcha:** https://cblazquezbruno-ux.github.io/lamuralla-local-app/
- **Base de datos y servidor:** Supabase, proyecto `la-muralla-local` (ref. `ugwzbcrvamfpxpcfldag`, servidores en París)
- **Pagos:** PayPal (suscripción mensual + pagos sueltos de extras). Ahora mismo en **modo prueba**.

## Qué hace

**Local (cliente):** portada con la campaña de Talavera · alta en 5 pasos con pago del primer mes · calendario para reservar el día de rodaje (ticket con cuenta atrás y añadir al calendario) · "Qué necesitamos de ti" con checklist y guiones · lo que paga este mes, días extra y presupuestos de eventos · historial de pagos · chat privado con el equipo · asistente privado · perfil, accesos a redes, contrato y baja · avisos al móvil.

**Equipo (admin):** panel con locales activos, cuotas y plazas · agenda para abrir días y franjas · avisos de eventos y bajas · fichas de cliente (precio, IVA y paquete a medida, guiones, contraseña de Instagram cifrada) · chat con cada local · ajustes de precios, campaña, condiciones y PayPal · copias de seguridad · cuentas de equipo.

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

## Cuentas de prueba

- Cliente demo: `La muralla1`
- Equipo demo: `La muralla2`

(Contraseñas aparte. Para el equipo real, crea cuentas propias en Ajustes › Equipo.)
