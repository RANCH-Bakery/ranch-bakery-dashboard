# RANCH Bakery Owner Dashboard — Reference

Snapshot date: 2026-08-09. This covers what exists today so you (or anyone helping you later) can maintain it without re-discovering everything from scratch.

## What it is

`ranch-bakery-crm.html` is a single self-contained web page — no install, no build step. Open it in a browser and it runs. It talks to a live Supabase project ("RANCH Bakery Operational Dashboard," ref `yhrqzgcvxzezaakduvey`, us-east-2) for all data: orders, customers, products, rewards, alerts.

**It needs internet access to work**, even though it's a local file. On load it pulls React, ReactDOM, the Supabase client, Chart.js, EmailJS, and Babel from CDNs (unpkg.com, cdn.jsdelivr.net), then talks to Supabase directly from your browser. If any of those can't be reached — dead wifi, a network that blocks unpkg/jsdelivr, an aggressive ad/content blocker — the page won't start.

## Logging in

It's gated by Supabase Auth (email + password), pre-filled with `ranchmarq@gmail.com`. There's a "Change password" option once you're in. Anyone without the password sees only the login screen — they can't see your data. Your customers never log in; they use the separate public order form (`index.html`), which only has permission to create orders and read products, not to browse your customer list or history.

## The seven tabs

- **Dashboard** — revenue this week, this Tuesday's order count, in-progress orders, unresolved alerts, top customer/item/margin item (month or year), a 12-month revenue chart, recent orders, top products (30 days).
- **Tuesday Batches** — every order grouped by delivery Tuesday (or by month/year/customer), collapsible, with a "what to bake" chip list per batch. This week's batch auto-expands.
- **Orders** — kanban board (pending → confirmed → baking → ready → fulfilled) or a filterable/sortable table. Fulfilled orders from past months auto-move into a collapsed Archive so the board stays current. Every status change requires a typed reason, logged permanently to that order's history.
- **Customers** — every customer, lifetime value, punch-card progress, order history.
- **Products** — edit price, cost of goods, and stock inline; margin recalculates live.
- **Rewards** — the punch-card queue (see below), with an undo if one gets redeemed by mistake.
- **Alerts** — high-value orders ($500+) and reward reminders, auto-generated, dismissible.

## Business rules baked into the database (not just the UI)

These live as Postgres triggers/functions, so they hold even if someone edits the data directly in Supabase, not just through the dashboard:

- **Delivery always lands on a Tuesday.** New orders auto-assign the next Tuesday, unless it's past the **Friday-before at 8:00 PM Eastern** cutoff, in which case they roll to the Tuesday after.
- **Punch card:** $10 of *fulfilled* spend = 1 point. 10 points ($100 spent) = 1 reward, auto-issued the moment an order is marked fulfilled. Redemption is manual, from the order drawer, so it's always tied to an actual discount.
- **High-value alert:** any order totaling $500+ gets flagged automatically.
- **Status changes are logged** with who changed it, when, and why (reason is required — enforced by the database, not just the form).

## Data model

See `RANCH_Dashboard_Schema_Reference.sql` for the full column-by-column snapshot, RLS policies, and function definitions, pulled directly from the live database. Short version: `products`, `customers`, `orders` → `order_items`, plus `order_status_log`, `alerts`, `communications`, and `customer_rewards`. Every table has row-level security on — reads/writes are gated by role (`authenticated` = you, logged in; `anon`/`public` = your storefront's guest order form, which can only do a few narrow, whitelisted things).

## About the "blank screen" / startup error

I read through the entire file end-to-end and didn't find a code bug — no broken syntax, no bad references, and the database side checked out clean (RLS intact, no schema drift, no errors in the advisors). The real problem was that the page had **no error handling** — if anything failed before or during render, you'd see nothing at all, with no clue why. I fixed that: a failed startup now shows an actual message instead of a blank page, and a React error boundary catches any future in-app rendering crash the same way.

Once that fix was in, the real error showed up: `Uncaught SyntaxError: Failed to execute 'appendChild' on 'Node': Cannot use import statement outside a module`. I checked the actual content of every CDN script the dashboard loads (Supabase, Chart.js, EmailJS) — none of them contain that syntax. That specific error signature is a well-documented symptom of a **browser extension** injecting a script into the page incorrectly (Grammarly, a crypto wallet like MetaMask, React DevTools, and similar are the usual suspects), especially common when a page is opened as a local `file://` file rather than served over `http(s)` — which is how you're opening this one.

**If it happens again:** try Incognito/Private mode first (extensions are off by default there) — if it loads clean, an extension is the cause. Disable extensions one at a time in your normal window (starting with Grammarly and any crypto wallet) until you find the culprit. The error message on screen now explains this directly if it detects that specific error pattern, and for anything else, open dev tools (F12 or Cmd+Option+I), check the Console tab, and send me what's there.

## Known, intentional trade-offs (not bugs)

- Four database functions (`lookup_customer_by_email`, `submit_guest_order`, `update_order_status`, `upsert_customer_self`) are callable without logging in. That's deliberate — your public order form needs to create orders and look up returning customers without an account. Each one is narrowly scoped (e.g. `update_order_status` still checks `auth.role() = 'authenticated'` internally before it'll do anything).
- Supabase's "leaked password protection" (checks new passwords against known breach lists) is currently off for this project. Cheap to turn on in Supabase Auth settings if you want it — not urgent, just worth knowing it's off.

## Where things live

- Dashboard file: `ranch-bakery-crm.html` (this folder)
- Guest order form: `index.html`
- Database: Supabase project `yhrqzgcvxzezaakduvey`, region us-east-2
- Transactional email: EmailJS (service `service_bimnpul`) — order-ready emails are wired up; the reward-earned template is still blank (`EMAILJS_REWARD_EARNED_TEMPLATE_ID`) and those emails are silently skipped until you create that template and fill in the ID inside the file (search for that variable name near the top of the script).
