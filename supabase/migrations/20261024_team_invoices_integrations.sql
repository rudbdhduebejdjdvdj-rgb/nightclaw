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
