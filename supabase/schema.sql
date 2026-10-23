-- Revora initial multi-company schema for Supabase/PostgreSQL.
-- Apply only after creating a Supabase project, in its SQL Editor.
-- All exposed business tables use RLS and scope records to an organization.

create extension if not exists pgcrypto;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 120),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member')),
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

create table if not exists public.contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  kind text not null check (kind in ('customer','supplier','both')),
  name text not null check (char_length(trim(name)) between 1 and 180),
  email text,
  phone text,
  tax_id text,
  address text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sku text,
  name text not null check (char_length(trim(name)) between 1 and 180),
  description text,
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  stock_quantity numeric(12,3) not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku)
);

create table if not exists public.sales_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid references public.contacts(id) on delete set null,
  order_number text not null,
  status text not null default 'draft' check (status in ('draft','sent','confirmed','fulfilled','cancelled')),
  currency char(3) not null default 'EUR',
  issue_date date not null default current_date,
  due_date date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, order_number)
);

create table if not exists public.sales_order_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sales_order_id uuid not null references public.sales_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  description text not null,
  quantity numeric(12,3) not null default 1 check (quantity > 0),
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  tax_rate numeric(5,2) not null default 0 check (tax_rate between 0 and 100),
  created_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  description text not null,
  category text,
  amount numeric(12,2) not null check (amount >= 0),
  currency char(3) not null default 'EUR',
  expense_date date not null default current_date,
  supplier_id uuid references public.contacts(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists organization_members_user_idx on public.organization_members(user_id);
create index if not exists contacts_org_kind_idx on public.contacts(organization_id, kind);
create index if not exists products_org_name_idx on public.products(organization_id, name);
create index if not exists sales_orders_org_date_idx on public.sales_orders(organization_id, issue_date desc);
create index if not exists sales_order_items_order_idx on public.sales_order_items(sales_order_id);
create index if not exists expenses_org_date_idx on public.expenses(organization_id, expense_date desc);

-- Membership checks run with a restricted, fixed search_path. Execute is not public.
create or replace function public.is_org_member(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = target_org and m.user_id = (select auth.uid())
  );
$$;

create or replace function public.has_org_role(target_org uuid, allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = target_org
      and m.user_id = (select auth.uid())
      and m.role = any(allowed_roles)
  );
$$;

revoke all on function public.is_org_member(uuid) from public, anon;
revoke all on function public.has_org_role(uuid, text[]) from public, anon;
grant execute on function public.is_org_member(uuid) to authenticated;
grant execute on function public.has_org_role(uuid, text[]) to authenticated;

-- Create an organization and its first owner atomically; prevents self-joining arbitrary orgs.
create or replace function public.create_organization(org_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_org_id uuid;
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;
  if org_name is null or char_length(trim(org_name)) < 2 or char_length(trim(org_name)) > 120 then
    raise exception 'Organization name must be between 2 and 120 characters';
  end if;

  insert into public.organizations(name, created_by)
  values (trim(org_name), current_user_id)
  returning id into new_org_id;

  insert into public.organization_members(organization_id, user_id, role)
  values (new_org_id, current_user_id, 'owner');

  return new_org_id;
end;
$$;

revoke all on function public.create_organization(text) from public, anon;
grant execute on function public.create_organization(text) to authenticated;

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.contacts enable row level security;
alter table public.products enable row level security;
alter table public.sales_orders enable row level security;
alter table public.sales_order_items enable row level security;
alter table public.expenses enable row level security;

create policy "members can read their organizations"
on public.organizations for select to authenticated
using (public.is_org_member(id));

create policy "owners and admins can update their organizations"
on public.organizations for update to authenticated
using (public.has_org_role(id, array['owner','admin']))
with check (public.has_org_role(id, array['owner','admin']));

create policy "members can read organization membership"
on public.organization_members for select to authenticated
using (public.is_org_member(organization_id));

create policy "owners and admins can add members"
on public.organization_members for insert to authenticated
with check (
  public.has_org_role(organization_id, array['owner','admin'])
  and role in ('admin','member')
);

create policy "only owners can change member roles"
on public.organization_members for update to authenticated
using (public.has_org_role(organization_id, array['owner']))
with check (
  public.has_org_role(organization_id, array['owner'])
  and role in ('admin','member')
);

create policy "owners remove members and admins remove non-owners"
on public.organization_members for delete to authenticated
using (
  public.has_org_role(organization_id, array['owner'])
  or (public.has_org_role(organization_id, array['admin']) and role <> 'owner')
);

create policy "members manage contacts"
on public.contacts for all to authenticated
using (public.is_org_member(organization_id))
with check (public.is_org_member(organization_id));

create policy "members manage products"
on public.products for all to authenticated
using (public.is_org_member(organization_id))
with check (public.is_org_member(organization_id));

create policy "members manage sales orders"
on public.sales_orders for all to authenticated
using (public.is_org_member(organization_id))
with check (
  public.is_org_member(organization_id)
  and (customer_id is null or exists (
    select 1 from public.contacts c
    where c.id = sales_orders.customer_id and c.organization_id = sales_orders.organization_id
  ))
);

create policy "members manage sales order items"
on public.sales_order_items for all to authenticated
using (public.is_org_member(organization_id))
with check (
  public.is_org_member(organization_id)
  and exists (
    select 1 from public.sales_orders so
    where so.id = sales_order_items.sales_order_id and so.organization_id = sales_order_items.organization_id
  )
  and (product_id is null or exists (
    select 1 from public.products p
    where p.id = sales_order_items.product_id and p.organization_id = sales_order_items.organization_id
  ))
);

create policy "members manage expenses"
on public.expenses for all to authenticated
using (public.is_org_member(organization_id))
with check (
  public.is_org_member(organization_id)
  and (supplier_id is null or exists (
    select 1 from public.contacts c
    where c.id = expenses.supplier_id and c.organization_id = expenses.organization_id
  ))
);

-- Grant API access explicitly; RLS above remains the row-level security boundary.
grant select, insert, update, delete on public.organizations to authenticated;
grant select, insert, update, delete on public.organization_members to authenticated;
grant select, insert, update, delete on public.contacts to authenticated;
grant select, insert, update, delete on public.products to authenticated;
grant select, insert, update, delete on public.sales_orders to authenticated;
grant select, insert, update, delete on public.sales_order_items to authenticated;
grant select, insert, update, delete on public.expenses to authenticated;


-- Canonical bootstrap extension: the following additive migrations bring a fresh install to the same schema as the active Revora project.


-- BEGIN 20261023222629_revora_team_invoices_integrations.sql
-- Revora collaboration, internal invoices, integrations and company settings.
-- Safe additive migration; no existing business rows are removed.

alter table public.organization_members add column if not exists email text, add column if not exists display_name text;
update public.organization_members m set email=u.email, display_name=coalesce(nullif(u.raw_user_meta_data->>'full_name',''),split_part(coalesce(u.email,''),'@',1)) from auth.users u where u.id=m.user_id and (m.email is null or m.display_name is null);
alter table public.products add column if not exists min_stock numeric(12,3) not null default 0;
alter table public.contacts add column if not exists company text;
alter table public.organizations add column if not exists legal_name text, add column if not exists tax_id text, add column if not exists address text, add column if not exists phone text, add column if not exists billing_email text, add column if not exists currency char(3) not null default 'EUR', add column if not exists default_tax_rate numeric(5,2) not null default 21 check(default_tax_rate between 0 and 100);

create table if not exists public.organization_invites (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
 email text not null, role text not null default 'member' check(role in ('admin','member')), token uuid not null unique default gen_random_uuid(),
 invited_by uuid not null references auth.users(id) on delete restrict, expires_at timestamptz not null default(now()+interval '7 days'),
 accepted_at timestamptz, created_at timestamptz not null default now()
);
create unique index if not exists organization_invites_pending_email_idx on public.organization_invites(organization_id,lower(email)) where accepted_at is null;
create index if not exists organization_invites_token_idx on public.organization_invites(token);

create table if not exists public.team_messages (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade, user_name text not null default 'Usuario', user_email text,
 body text not null check(char_length(trim(body)) between 1 and 4000), created_at timestamptz not null default now()
);
create index if not exists team_messages_org_created_idx on public.team_messages(organization_id,created_at desc);
create or replace function public.set_team_message_author() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.user_id<>(select auth.uid()) then raise exception 'Invalid message author'; end if;
 select coalesce(nullif(u.raw_user_meta_data->>'full_name',''),split_part(coalesce(u.email,''),'@',1)),u.email into new.user_name,new.user_email from auth.users u where u.id=new.user_id;
 return new;
end; $$;
drop trigger if exists team_message_author_trigger on public.team_messages;
create trigger team_message_author_trigger before insert on public.team_messages for each row execute function public.set_team_message_author();

create table if not exists public.invoices (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
 customer_id uuid references public.contacts(id) on delete set null, invoice_number text not null,
 status text not null default 'draft' check(status in ('draft','issued','paid','void')), currency char(3) not null default 'EUR',
 issue_date date not null default current_date, due_date date, subtotal numeric(12,2) not null default 0 check(subtotal>=0),
 tax_total numeric(12,2) not null default 0 check(tax_total>=0), total numeric(12,2) not null default 0 check(total>=0),
 notes text, created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), unique(organization_id,invoice_number)
);
create table if not exists public.invoice_items (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
 invoice_id uuid not null references public.invoices(id) on delete cascade, product_id uuid references public.products(id) on delete set null,
 description text not null, quantity numeric(12,3) not null default 1 check(quantity>0),
 unit_price numeric(12,2) not null default 0 check(unit_price>=0), tax_rate numeric(5,2) not null default 0 check(tax_rate between 0 and 100),
 created_at timestamptz not null default now()
);
create index if not exists invoices_org_date_idx on public.invoices(organization_id,issue_date desc);
create index if not exists invoice_items_invoice_idx on public.invoice_items(invoice_id);

create table if not exists public.organization_integrations (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete cascade,
 provider text not null check(provider in ('google_calendar','gmail','slack','microsoft_365','stripe','shopify','zapier','make','webhook')),
 status text not null default 'setup_required' check(status in ('disconnected','setup_required','connected','error')),
 account_label text, account_url text, settings jsonb not null default '{}'::jsonb, last_checked_at timestamptz,
 created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), unique(organization_id,provider)
);

create or replace function public.create_organization(org_name text) returns uuid language plpgsql security definer set search_path='' as $$
declare new_org_id uuid; current_user_id uuid:=(select auth.uid()); current_email text; current_name text;
begin
 if current_user_id is null then raise exception 'Authentication required'; end if;
 if org_name is null or char_length(trim(org_name))<2 or char_length(trim(org_name))>120 then raise exception 'Organization name must be between 2 and 120 characters'; end if;
 select u.email,coalesce(nullif(u.raw_user_meta_data->>'full_name',''),split_part(coalesce(u.email,''),'@',1)) into current_email,current_name from auth.users u where u.id=current_user_id;
 insert into public.organizations(name,created_by) values(trim(org_name),current_user_id) returning id into new_org_id;
 insert into public.organization_members(organization_id,user_id,role,email,display_name) values(new_org_id,current_user_id,'owner',current_email,current_name);
 return new_org_id;
end; $$;
revoke all on function public.create_organization(text) from public,anon;
grant execute on function public.create_organization(text) to authenticated;

create or replace function public.create_org_invite(target_org uuid,invite_email text,member_role text default 'member') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=(select auth.uid()); email_clean text:=lower(trim(invite_email)); result_row record;
begin
 if actor_id is null then raise exception 'Authentication required'; end if;
 if not public.has_org_role(target_org,array['owner','admin']) then raise exception 'No tienes permiso para invitar miembros'; end if;
 if email_clean is null or length(email_clean)<5 or position('@' in email_clean)<2 or position(' ' in email_clean)>0 then raise exception 'Correo electrónico no válido'; end if;
 if member_role not in ('member','admin') then raise exception 'Rol no válido'; end if;
 if exists(select 1 from auth.users u join public.organization_members m on m.user_id=u.id where m.organization_id=target_org and lower(u.email)=email_clean) then raise exception 'Esta persona ya pertenece a la empresa'; end if;
 delete from public.organization_invites where organization_id=target_org and lower(email)=email_clean and accepted_at is null;
 insert into public.organization_invites(organization_id,email,role,invited_by) values(target_org,email_clean,member_role,actor_id) returning id,token,email,expires_at into result_row;
 return jsonb_build_object('id',result_row.id,'token',result_row.token,'email',result_row.email,'expires_at',result_row.expires_at);
end; $$;
revoke all on function public.create_org_invite(uuid,text,text) from public,anon;
grant execute on function public.create_org_invite(uuid,text,text) to authenticated;

create or replace function public.accept_org_invite(invite_token uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=(select auth.uid()); actor_email text; actor_name text; invite_row public.organization_invites%rowtype;
begin
 if actor_id is null then raise exception 'Authentication required'; end if;
 select u.email,coalesce(nullif(u.raw_user_meta_data->>'full_name',''),split_part(coalesce(u.email,''),'@',1)) into actor_email,actor_name from auth.users u where u.id=actor_id;
 if actor_email is null then raise exception 'No se pudo verificar el correo'; end if;
 select * into invite_row from public.organization_invites i where i.token=invite_token and lower(i.email)=lower(actor_email) and i.accepted_at is null and i.expires_at>now() order by i.created_at desc limit 1 for update;
 if not found then raise exception 'La invitación no existe, ha caducado o pertenece a otro correo'; end if;
 insert into public.organization_members(organization_id,user_id,role,email,display_name) values(invite_row.organization_id,actor_id,invite_row.role,actor_email,actor_name)
 on conflict(organization_id,user_id) do update set email=excluded.email,display_name=excluded.display_name;
 update public.organization_invites set accepted_at=now() where id=invite_row.id;
 return invite_row.organization_id;
end; $$;
revoke all on function public.accept_org_invite(uuid) from public,anon;
grant execute on function public.accept_org_invite(uuid) to authenticated;

alter table public.organization_invites enable row level security;
alter table public.team_messages enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.organization_integrations enable row level security;

create policy "admins read invites" on public.organization_invites for select to authenticated using(public.has_org_role(organization_id,array['owner','admin']));
create policy "members read team messages" on public.team_messages for select to authenticated using(public.is_org_member(organization_id));
create policy "members send own team messages" on public.team_messages for insert to authenticated with check(public.is_org_member(organization_id) and user_id=(select auth.uid()) and char_length(trim(body)) between 1 and 4000);
create policy "members manage invoices" on public.invoices for all to authenticated using(public.is_org_member(organization_id)) with check(public.is_org_member(organization_id) and (customer_id is null or exists(select 1 from public.contacts c where c.id=invoices.customer_id and c.organization_id=invoices.organization_id)));
create policy "members manage invoice items" on public.invoice_items for all to authenticated using(public.is_org_member(organization_id)) with check(public.is_org_member(organization_id) and exists(select 1 from public.invoices i where i.id=invoice_items.invoice_id and i.organization_id=invoice_items.organization_id) and (product_id is null or exists(select 1 from public.products p where p.id=invoice_items.product_id and p.organization_id=invoice_items.organization_id)));
create policy "members read integrations" on public.organization_integrations for select to authenticated using(public.is_org_member(organization_id));
create policy "admins manage integrations" on public.organization_integrations for all to authenticated using(public.has_org_role(organization_id,array['owner','admin'])) with check(public.has_org_role(organization_id,array['owner','admin']));
drop policy if exists "owners and admins can add members" on public.organization_members;
grant select on public.organization_invites to authenticated;
grant select,insert on public.team_messages to authenticated;
grant select,insert,update,delete on public.invoices to authenticated;
grant select,insert,update,delete on public.invoice_items to authenticated;
grant select,insert,update,delete on public.organization_integrations to authenticated;

do $$ begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='team_messages') then alter publication supabase_realtime add table public.team_messages; end if;
end $$;

-- END 20261023222629_revora_team_invoices_integrations.sql


-- BEGIN 20261023222941_revora_company_profile.sql
-- Additional business profile fields for Revora organizations.
alter table public.organizations
  add column if not exists legal_name text,
  add column if not exists tax_id text,
  add column if not exists address text,
  add column if not exists phone text,
  add column if not exists billing_email text,
  add column if not exists currency char(3) not null default 'EUR',
  add column if not exists default_tax_rate numeric(5,2) not null default 21 check (default_tax_rate between 0 and 100);

-- END 20261023222941_revora_company_profile.sql


-- BEGIN 20261023223300_revora_security_and_index_hardening.sql
-- Harden trigger execution and remove overlapping integration policies; add useful FK indexes.
revoke all on function public.set_team_message_author() from public, anon, authenticated;
drop policy if exists "admins manage integrations" on public.organization_integrations;
create policy "admins insert integrations" on public.organization_integrations for insert to authenticated with check (public.has_org_role(organization_id, array['owner','admin']));
create policy "admins update integrations" on public.organization_integrations for update to authenticated using (public.has_org_role(organization_id, array['owner','admin'])) with check (public.has_org_role(organization_id, array['owner','admin']));
create policy "admins delete integrations" on public.organization_integrations for delete to authenticated using (public.has_org_role(organization_id, array['owner','admin']));
create index if not exists expenses_supplier_idx on public.expenses(supplier_id);
create index if not exists invoice_items_org_idx on public.invoice_items(organization_id);
create index if not exists invoice_items_product_idx on public.invoice_items(product_id);
create index if not exists invoices_customer_idx on public.invoices(customer_id);
create index if not exists invoices_created_by_idx on public.invoices(created_by);
create index if not exists integrations_created_by_idx on public.organization_integrations(created_by);
create index if not exists organization_invites_invited_by_idx on public.organization_invites(invited_by);
create index if not exists organizations_created_by_idx on public.organizations(created_by);
create index if not exists sales_order_items_org_idx on public.sales_order_items(organization_id);
create index if not exists sales_order_items_product_idx on public.sales_order_items(product_id);
create index if not exists sales_orders_customer_idx on public.sales_orders(customer_id);
create index if not exists team_messages_user_idx on public.team_messages(user_id);

-- END 20261023223300_revora_security_and_index_hardening.sql


-- BEGIN 20261023223341_revora_private_policy_helpers.sql
-- Move RLS helpers out of the exposed API schema while preserving policies.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;
create or replace function private.is_org_member(target_org uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_members m where m.organization_id=target_org and m.user_id=(select auth.uid()));
$$;
create or replace function private.has_org_role(target_org uuid, allowed_roles text[]) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.organization_members m where m.organization_id=target_org and m.user_id=(select auth.uid()) and m.role=any(allowed_roles));
$$;
revoke all on function private.is_org_member(uuid) from public,anon;
revoke all on function private.has_org_role(uuid,text[]) from public,anon;
grant execute on function private.is_org_member(uuid) to authenticated;
grant execute on function private.has_org_role(uuid,text[]) to authenticated;

drop policy if exists "members can read their organizations" on public.organizations;
drop policy if exists "owners and admins can update their organizations" on public.organizations;
drop policy if exists "members can read organization membership" on public.organization_members;
drop policy if exists "only owners can change member roles" on public.organization_members;
drop policy if exists "owners remove members and admins remove non-owners" on public.organization_members;
drop policy if exists "members manage contacts" on public.contacts;
drop policy if exists "members manage products" on public.products;
drop policy if exists "members manage sales orders" on public.sales_orders;
drop policy if exists "members manage sales order items" on public.sales_order_items;
drop policy if exists "members manage expenses" on public.expenses;
drop policy if exists "admins read invites" on public.organization_invites;
drop policy if exists "members read team messages" on public.team_messages;
drop policy if exists "members send own team messages" on public.team_messages;
drop policy if exists "members manage invoices" on public.invoices;
drop policy if exists "members manage invoice items" on public.invoice_items;
drop policy if exists "members read integrations" on public.organization_integrations;
drop policy if exists "admins insert integrations" on public.organization_integrations;
drop policy if exists "admins update integrations" on public.organization_integrations;
drop policy if exists "admins delete integrations" on public.organization_integrations;

create policy "members can read their organizations" on public.organizations for select to authenticated using(private.is_org_member(id));
create policy "owners and admins can update their organizations" on public.organizations for update to authenticated using(private.has_org_role(id,array['owner','admin'])) with check(private.has_org_role(id,array['owner','admin']));
create policy "members can read organization membership" on public.organization_members for select to authenticated using(private.is_org_member(organization_id));
create policy "only owners can change member roles" on public.organization_members for update to authenticated using(private.has_org_role(organization_id,array['owner'])) with check(private.has_org_role(organization_id,array['owner']) and role in ('admin','member'));
create policy "owners remove members and admins remove non-owners" on public.organization_members for delete to authenticated using(private.has_org_role(organization_id,array['owner']) or (private.has_org_role(organization_id,array['admin']) and role<>'owner'));
create policy "members manage contacts" on public.contacts for all to authenticated using(private.is_org_member(organization_id)) with check(private.is_org_member(organization_id));
create policy "members manage products" on public.products for all to authenticated using(private.is_org_member(organization_id)) with check(private.is_org_member(organization_id));
create policy "members manage sales orders" on public.sales_orders for all to authenticated using(private.is_org_member(organization_id)) with check(private.is_org_member(organization_id) and (customer_id is null or exists(select 1 from public.contacts c where c.id=sales_orders.customer_id and c.organization_id=sales_orders.organization_id)));
create policy "members manage sales order items" on public.sales_order_items for all to authenticated using(private.is_org_member(organization_id)) with check(private.is_org_member(organization_id) and exists(select 1 from public.sales_orders so where so.id=sales_order_items.sales_order_id and so.organization_id=sales_order_items.organization_id) and (product_id is null or exists(select 1 from public.products p where p.id=sales_order_items.product_id and p.organization_id=sales_order_items.organization_id)));
create policy "members manage expenses" on public.expenses for all to authenticated using(private.is_org_member(organization_id)) with check(private.is_org_member(organization_id) and (supplier_id is null or exists(select 1 from public.contacts c where c.id=expenses.supplier_id and c.organization_id=expenses.organization_id)));
create policy "admins read invites" on public.organization_invites for select to authenticated using(private.has_org_role(organization_id,array['owner','admin']));
create policy "members read team messages" on public.team_messages for select to authenticated using(private.is_org_member(organization_id));
create policy "members send own team messages" on public.team_messages for insert to authenticated with check(private.is_org_member(organization_id) and user_id=(select auth.uid()) and char_length(trim(body)) between 1 and 4000);
create policy "members manage invoices" on public.invoices for all to authenticated using(private.is_org_member(organization_id)) with check(private.is_org_member(organization_id) and (customer_id is null or exists(select 1 from public.contacts c where c.id=invoices.customer_id and c.organization_id=invoices.organization_id)));
create policy "members manage invoice items" on public.invoice_items for all to authenticated using(private.is_org_member(organization_id)) with check(private.is_org_member(organization_id) and exists(select 1 from public.invoices i where i.id=invoice_items.invoice_id and i.organization_id=invoice_items.organization_id) and (product_id is null or exists(select 1 from public.products p where p.id=invoice_items.product_id and p.organization_id=invoice_items.organization_id)));
create policy "members read integrations" on public.organization_integrations for select to authenticated using(private.is_org_member(organization_id));
create policy "admins insert integrations" on public.organization_integrations for insert to authenticated with check(private.has_org_role(organization_id,array['owner','admin']));
create policy "admins update integrations" on public.organization_integrations for update to authenticated using(private.has_org_role(organization_id,array['owner','admin'])) with check(private.has_org_role(organization_id,array['owner','admin']));
create policy "admins delete integrations" on public.organization_integrations for delete to authenticated using(private.has_org_role(organization_id,array['owner','admin']));
create or replace function public.create_org_invite(target_org uuid,invite_email text,member_role text default 'member') returns jsonb language plpgsql security definer set search_path='' as $$
declare actor_id uuid:=(select auth.uid()); email_clean text:=lower(trim(invite_email)); result_row record;
begin
 if actor_id is null then raise exception 'Authentication required'; end if;
 if not private.has_org_role(target_org,array['owner','admin']) then raise exception 'No tienes permiso para invitar miembros'; end if;
 if email_clean is null or length(email_clean)<5 or position('@' in email_clean)<2 or position(' ' in email_clean)>0 then raise exception 'Correo electrónico no válido'; end if;
 if member_role not in ('member','admin') then raise exception 'Rol no válido'; end if;
 if exists(select 1 from auth.users u join public.organization_members m on m.user_id=u.id where m.organization_id=target_org and lower(u.email)=email_clean) then raise exception 'Esta persona ya pertenece a la empresa'; end if;
 delete from public.organization_invites where organization_id=target_org and lower(email)=email_clean and accepted_at is null;
 insert into public.organization_invites(organization_id,email,role,invited_by) values(target_org,email_clean,member_role,actor_id) returning id,token,email,expires_at into result_row;
 return jsonb_build_object('id',result_row.id,'token',result_row.token,'email',result_row.email,'expires_at',result_row.expires_at);
end; $$;
revoke all on function public.is_org_member(uuid) from public,anon,authenticated;
revoke all on function public.has_org_role(uuid,text[]) from public,anon,authenticated;

-- END 20261023223341_revora_private_policy_helpers.sql
