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
