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
