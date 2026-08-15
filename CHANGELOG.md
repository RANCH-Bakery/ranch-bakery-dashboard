# RANCH Bakery Dashboard — Build History

Pulled from the actual database migration log, so this is exactly what changed and when (not a reconstruction from memory).

## Aug 1, 2026 — Foundation
- Created the core tables: products, customers, orders, order_items.
- Added a `delivery_date` column to orders (separate from `requested_date`), since delivery is always assigned to a Tuesday regardless of when the order was placed.

## Aug 2, 2026 — Security lockdown, automation, and features (one long build day)
Roughly in order:
- Added the products "update" policy and the $500+ high-value order alert trigger.
- Reset the owner login and locked down what the public can `SELECT` — this is when the dashboard stopped being fully open and started requiring login.
- Added an "update" policy for orders.
- Multiple passes revoking public/anon execute permission on trigger functions and restricting update policies to logged-in users only — tightening access after the initial build so guests can't read or write anything they shouldn't.
- Restricted direct INSERT on alerts, products, and communications tables.
- **Auto-compute delivery date**: new trigger that assigns every order to the next valid Tuesday, rolling to the following week if placed after the Friday 8pm Eastern cutoff.
- Added `lookup_customer_by_email` and `upsert_customer_self` — the two RPCs your guest order form uses to recognize returning customers without needing a login.
- Pinned the `search_path` on the delivery-date trigger (a Postgres security hardening step for `SECURITY DEFINER` functions).
- Added `order_status_log` — full audit trail of every status change, with reason and who changed it.
- **Punch-card rewards**: built the `customer_rewards` table and the auto-earn trigger.
- Added `discount_amount` / `discount_reason` columns to orders, for comps and punch-card redemptions.
- **Switched rewards from order-count-based to dollar-based points** ($10 spent = 1 point, $100 = 1 reward) — a real correction, since a flat "every Nth order" scheme would have unfairly rewarded small orders the same as large ones.
- Another round of revoking public execute on newly-added trigger functions.
- Added `submit_guest_order` — the single RPC that lets your storefront create a full order (with line items) in one transaction, without ever touching the orders/customers tables directly.
- Locked down direct writes to authenticated-only across the board (guests must go through the narrow RPCs above, nothing else).
- Added the reward-reminder alert trigger — flags an order if that customer already has an unredeemed reward sitting there.
- Added `earned_email_sent` flag to `customer_rewards`, to track whether the "you earned a reward" email has gone out (avoids double-sending).

## Aug 9, 2026 — Dashboard resilience
- Fixed a formatting bug on the COGS/margin workbook's pricing tab (unrelated file, same session).
- Investigated a reported blank-screen issue on the dashboard. Found no code or database bug — everything checked out clean — which points to something environmental (a CDN script failing to load). Added:
  - A page-level error catcher so a failed CDN load shows an actual message instead of a blank screen.
  - A React error boundary so a future in-app rendering error shows the real error instead of silently unmounting to blank.

## Features built across the session, not all separately migration-tracked
- Manual/phone order entry form (for orders that don't come through the storefront).
- MTD/YTD dashboard highlight cards and the 12-month revenue trend chart.
- Tuesday Batches tab reworked into collapsible groups with month/year/customer views.
- Orders tab: Excel-style per-column filter/sort, plus an Archive section for old fulfilled orders so the active board doesn't get cluttered.
- Delivery location converted from free text to a fixed school dropdown.
- Order-ready customer email wired up via EmailJS (reward-earned email template still needs to be created and its ID filled in — see the README).
- CSV import path designed for historical order data from your old Microsoft Forms process (used to backfill several weeks of real historical orders).
