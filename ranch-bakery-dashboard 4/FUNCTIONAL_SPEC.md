# RANCH Bakery Dashboard — Functional Spec

This describes what the dashboard is *supposed* to do, independent of the code. Use it to tell the difference between "this is a bug" and "this is working as designed" when something looks off, and as the reference if the dashboard ever needs to be rebuilt or handed to a developer.

## Access

- Single login gate (Supabase Auth, email + password). Nobody sees any tab, any data, or even the app shell without signing in first.
- Password can be changed in-app. Changing it requires the current password (enforced by Supabase Auth settings).
- No customer ever logs into this dashboard. Customers use a separate, public order form that only has permission to submit orders and read the product list — never to browse orders, customers, or history.

## Dashboard tab

- **Revenue this week** = sum of `total` for all non-cancelled orders whose delivery date falls in the current Mon–Sun week.
- **Orders this Tuesday** = count of non-cancelled orders whose delivery date is the next upcoming assigned Tuesday (see delivery-date rule below).
- **In progress** = count of orders in status pending, confirmed, or baking.
- **Unresolved alerts** = count of alerts not yet marked resolved.
- **Business highlights** (This month / This year toggle): top customer by $ spent, most popular item by quantity sold, and top revenue item by *net margin* (unit price minus that product's cost of goods, times quantity) — not by raw revenue.
- **Revenue trend** = trailing 12 months, bucketed by delivery date (not order-placed date), bar chart.
- **Recent orders** = last 6 orders by created-at, regardless of status.
- **Top products** = last 30 days, ranked by quantity sold, from created-at.

## Tuesday Batches tab

- Every non-cancelled order with a delivery date, grouped by that date (default), or regroupable by month / year / customer.
- Each date group shows a "what to bake" summary: total quantity per product across every order landing that day.
- This week's group is expanded by default; everything else starts collapsed. Expand all / Collapse all available.
- Customer-grouping can sort by total revenue or alphabetically.

## Orders tab

- Two views: Kanban board (default) or a filterable/sortable table.
- **Board columns** = pending → confirmed → baking → ready → fulfilled, in that fixed order. Each card shows a one-click button to advance to the *next* status only (no skipping stages from the board — skipping requires opening the order and picking a status directly).
- **Any status change — from the board or the order drawer — requires a typed reason.** This is enforced twice: once in the UI (can't submit without text) and once in the database (the `update_order_status` function rejects an empty reason). A change made by editing the database directly (bypassing the app) logs with no reason and is tagged "changed outside the dashboard."
- **Archive**: once an order is `fulfilled` *and* its delivery month is no longer the current month, it disappears from the active board/table and moves into a collapsed, searchable Archive section at the bottom. This keeps the active view to "what's actually happening now."
- **Cancelled orders** are hidden from the board by default (toggle to show). Cancelling requires a reason like any other status change. A cancelled order can be reinstated to "pending."
- **Table view** supports Excel-style per-column filtering (checkbox list of distinct values, with search) and click-to-sort on any column.

## Customers tab

- One row per customer (matched by email if not linked by ID). Lifetime value = sum of `total` across that customer's non-cancelled orders.
- Punch-card progress shown per customer: points based on *fulfilled* spend only (see Rewards below), with "$X to next reward" or "reward ready" state.
- Clicking a customer opens their full order history.

## Products tab

- Inline-editable price, cost of goods, and stock quantity per product. Margin ($ and %) recalculates live as you type, before saving.
- Changes are staged locally (Save / Reset buttons appear) — nothing writes to the database until you click Save.

## Rewards tab (punch card)

- **Earning rule**: $10 of *fulfilled* spend = 1 point. 10 points ($100 fulfilled spend) = 1 reward. This is calculated and issued automatically by a database trigger the moment an order's status becomes `fulfilled` — not something the dashboard UI computes on its own, so it stays correct even if orders are updated outside the app.
- **Redemption is always manual**, and always happens from inside an order's drawer (not from the Rewards tab directly) — because redeeming should always tie to an actual discount applied to a real order, not just a checkbox.
- Redeeming applies either a flat $10 credit or a "50% off specialty loaf" note (dollar amount entered manually, since which item is "the specialty loaf" varies by order).
- Redemption can be undone from the Rewards tab. **Undoing only resets the reward's redeemed flag — it does NOT automatically remove or reverse the discount already applied to whatever order it was redeemed against.** If that order already shipped with a discount, removing the discount (if wanted) is a separate manual step in that order's drawer.

## Alerts tab

- Two auto-generated alert types, both created by database triggers (not the dashboard):
  - **High value**: any order totaling $500+ (and not cancelled).
  - **Reward reminder**: fires when a customer with an already-unredeemed reward places a new order — a nudge to consider applying it.
- Alerts can be marked resolved (one-way in the UI; there's no "unresolve"). Resolved alerts are hidden by default (toggle to show).

## Delivery date assignment (database-enforced, not just UI)

- Every order is assigned to a Tuesday.
- The cutoff for a given Tuesday's batch is **the Friday before, 8:00 PM Eastern**. An order placed after that cutoff rolls to the following Tuesday instead.
- This calculation happens in the database (`compute_order_delivery_date` trigger) using the `America/New_York` timezone explicitly, specifically so it's correct regardless of what timezone the browser or server happens to be in.
- The dashboard's own JS mirrors this same logic for display purposes (labeling "This Tuesday" / "Next Tuesday," computing what the *next* assignment would be) — but the database is what actually decides a real order's delivery date, and it will win over anything the UI shows if the two ever disagree.

## Manual order entry

- For phone or in-person orders that don't come through the public storefront.
- Supports picking an existing customer or entering a new one, multiple line items, pickup vs. delivery (delivery restricted to a fixed list of schools), and a note.

## Notifications

- "Order ready" email fires automatically the moment a status changes to `ready`, if the order has a customer email on file and the EmailJS template ID is configured. Silently skipped otherwise (no error shown) — this is intentional so an order can still be marked ready even if email isn't set up.
- "Reward earned" email is wired for the same mechanism but its template ID is currently blank, so those emails don't send yet.
