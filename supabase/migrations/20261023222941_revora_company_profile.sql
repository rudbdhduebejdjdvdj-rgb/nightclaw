-- Additional business profile fields for Revora organizations.
alter table public.organizations
  add column if not exists legal_name text,
  add column if not exists tax_id text,
  add column if not exists address text,
  add column if not exists phone text,
  add column if not exists billing_email text,
  add column if not exists currency char(3) not null default 'EUR',
  add column if not exists default_tax_rate numeric(5,2) not null default 21 check (default_tax_rate between 0 and 100);
