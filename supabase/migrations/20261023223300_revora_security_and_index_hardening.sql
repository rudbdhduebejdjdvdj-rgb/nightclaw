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
