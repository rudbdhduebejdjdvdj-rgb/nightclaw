# Revora backend foundation

This folder contains the first database schema for Revora, designed for multiple companies.

## What's included
- Organizations and memberships (owner/admin/member roles)
- Customers and suppliers (contacts)
- Products and stock quantities
- Sales orders and order lines
- Expenses
- Row Level Security (RLS) on every business table
- An authenticated function to create an organization and its first owner

## Setup
1. Create a Supabase project.
2. Open its SQL Editor.
3. Review and run `schema.sql`.
4. In Supabase Authentication, configure the desired sign-in methods and email confirmation.
5. Add the project's **publishable key** and project URL to the Revora frontend.
6. Never put a Supabase secret/service-role key in browser code.

## Important
The schema is a foundation, not yet a complete accounting or tax-compliance system. It does not yet implement invoices, payment reconciliation, VAT calculations, audit logs, inventory movements, or electronic invoicing requirements. Those need separate designs and tests before production use.
