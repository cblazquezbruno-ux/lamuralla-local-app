-- Ajustes iniciales (precios, condiciones, listas). Ejecutar una vez tras las migraciones.
insert into public.settings(id,data) values (1, $json${
 "iva": 21,
 "city": "Talavera de la Reina",
 "need": {
  "otro": [
   "Producto o servicio preparado para enseñar",
   "Equipo bien vestido",
   "Espacio limpio y recogido",
   "Leer los guiones que os mandamos"
  ],
  "salud": [
   "Ningún paciente en cámara sin consentimiento firmado",
   "5-10 preguntas frecuentes para responder a cámara",
   "Historiales y pantallas fuera de plano",
   "Bata o uniforme limpio",
   "Leer los guiones que os mandamos"
  ],
  "turismo": [
   "Habitaciones listas como para un cliente",
   "Actividades con figurantes",
   "Plan B si llueve",
   "Leer los guiones que os mandamos"
  ],
  "comercio": [
   "15-20 productos elegidos y limpios",
   "Escaparate montado",
   "Grabamos antes de abrir al público",
   "Equipo bien vestido",
   "Leer los guiones que os mandamos"
  ],
  "hosteleria": [
   "8-10 platos de la carta con la mise en place hecha",
   "Una mesa preparada junto a la mejor luz",
   "Equipo bien vestido y uniformado",
   "Local limpio y recogido antes de empezar",
   "Platos antes del servicio; ambiente durante",
   "Leer los guiones que os mandamos"
  ]
 },
 "plan": [
  "Grabamos 5-6 reels y 4 carruseles",
  "Fotos de producto y del local",
  "Clips para historias",
  "2-3 piezas hablando a cámara"
 ],
 "packs": [
  {
   "id": "imagen",
   "name": "Pack Imagen",
   "price": 390,
   "promo": 390,
   "setup": 0,
   "tagline": "Un mes de contenido profesional a partir de una jornada de grabación en tu negocio.",
   "features": [
    "1 jornada de grabación al mes (3-4 h)",
    "10-12 publicaciones al mes",
    "Historias los fines de semana",
    "Calendario mensual para aprobar",
    "Gestión y publicación en tus redes",
    "Informe mensual de resultados"
   ],
   "promoSetup": 0
  },
  {
   "id": "completo",
   "name": "Pack Completo",
   "price": 590,
   "promo": 590,
   "setup": 390,
   "tagline": "Todo el Pack Imagen, más un asistente con IA que atiende tu teléfono, tu WhatsApp y tu web.",
   "features": [
    "Todo el Pack Imagen",
    "Asistente IA al teléfono (300 min/mes)",
    "WhatsApp y chat web a cualquier hora",
    "Reservas con confirmación y recordatorio",
    "Respuestas a reseñas de Google",
    "Google Business al día",
    "Hasta 2 campañas de WhatsApp al mes"
   ],
   "promoSetup": 390
  }
 ],
 "paypal": {
  "clientId": "",
  "env": "sandbox",
  "plans": {
   "imagen": "",
   "completo": ""
  },
  "testMode": true
 },
 "contact": {
  "email": "hola@lamurallaproject.es",
  "phone": "650 503 871",
  "whatsapp": "34650503871"
 },
 "promoOn": true,
 "extraDay": 120,
 "minMonths": 3,
 "eventHours": 24,
 "noticeDays": 15,
 "promoTaken": 0,
 "promoTotal": 10,
 "changeHours": 48
}$json$::jsonb)
on conflict (id) do update set data = excluded.data;
