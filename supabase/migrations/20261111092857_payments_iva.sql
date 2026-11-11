-- payments_iva
alter table public.payments add column if not exists iva numeric; comment on column public.payments.iva is 'IVA aplicado en este cobro (%). Null = el general';
