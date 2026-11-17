# Paymos Ruby SDK

Official Ruby client for the Paymos Merchant API — invoices, withdrawals, refunds, balances,
and static per-customer wallets with their confirmed-deposit feed. Its only runtime dependency is
Ruby's official `base64` gem (required separately by modern Ruby versions).

```bash
gem install paymos
```

```ruby
require "paymos"

paymos = Paymos::Client.new(
  api_key: ENV.fetch("PAYMOS_API_KEY"),
  api_secret: ENV.fetch("PAYMOS_API_SECRET")
)

# Compatible amount-only call (products omitted or nil)
invoice = paymos.invoices.create(
  project_id: "prj_...",
  amount: "10.00",
  currency: "USD",
  external_order_id: "order_123"
)
paymos.invoices.each(status: [Paymos::InvoiceStatus::PAID]).each do |item|
  puts item.invoice_id
end
balances = paymos.balances.get
```

### Product line items (`products[]`)

Pass optional `products:` (`1..50` `Paymos::InvoiceProduct` instances or Hashes) to display purchase context on hosted checkout, or omit `products:` / pass `products: nil` for a compatible `amount-only` invoice. Each `Paymos::InvoiceProduct` requires `title:` (<= 200 Unicode scalar values), positive integer `quantity:`, and decimal string `unit_amount:` (in the invoice currency); `description:` (plain text, <= 2000 scalars) is an optional keyword and is omitted on the wire when `nil`.

```ruby
# 1-item invoice with optional description
studio_pro = Paymos::InvoiceProduct.new(
  title: "Studio Pro",
  description: "One-month access",
  quantity: 2,
  unit_amount: "24.50"
)
single_invoice = paymos.invoices.create(
  project_id: "prj_...",
  amount: "47.00",
  currency: "USD",
  external_order_id: "order_product_single",
  products: [studio_pro]
)

# Multi-item cart including a minimal 3-field item (no description)
cart_invoice = paymos.invoices.create(
  project_id: "prj_...",
  amount: "59.00",
  currency: "USD",
  external_order_id: "order_product_multi",
  products: [
    studio_pro,
    Paymos::InvoiceProduct.new(title: "Priority Support", quantity: 1, unit_amount: "12.00")
  ]
)

(cart_invoice.order.products || []).each do |item|
  puts "#{item.title} x#{item.quantity} @ #{item.unit_amount}"
end
```

- **Authoritative `amount`:** `amount` is the exact order total and is never recomputed from `sum(quantity * unit_amount)`.
- **First-success replay:** the first successful create freezes `order.products` on the invoice. Replaying the same `external_order_id` with unchanged `(amount, currency, network)` returns HTTP 200 with the original `Paymos::Invoice` and `order.products`, even if `products` changed; changing `(amount, currency, network)` raises `Paymos::ConflictError` (`409 invoice_idempotency_conflict`). Legacy and `amount-only` invoices return `order.products == nil`.
- **Webhooks:** signed invoice webhooks omit `products`.

Responses are immutable Ruby objects with documented RBS signatures (`sig/paymos.rbs`); request
keywords remain idiomatic `snake_case` and are converted directly to the Paymos
wire contract.

Create invoice refunds with a Payment key. The server calculates the amount and
returns it as a decimal string; there are no amount or destination arguments:

```ruby
refund = paymos.refunds.create(
  invoice_id: invoice.invoice_id,
  mode: Paymos::RefundMode::OVERPAYMENT,
  external_order_id: "refund_order_123_overpayment"
)
puts "#{refund.withdrawal_id}: #{refund.amount} #{refund.currency}"

filters = {
  invoice_id: invoice.invoice_id,
  status: [Paymos::WithdrawalStatus::COMPLETED],
  created_from: "2026-01-01T00:00:00Z",
  created_to: "2027-01-01T00:00:00Z",
  limit: 100
}
page = paymos.refunds.list(**filters)
next_page = paymos.refunds.list(**filters, cursor: page.next_cursor) if page.next_cursor
refund = paymos.refunds.get(refund.withdrawal_id)
```

`full` returns all remaining payment; `overpayment` returns all remaining excess.
For a payment of 120 against an invoice of 100, these are initially 120 and 20.
After the overpayment refund completes, a new full refund returns 100. Refunds
and their pages are immutable, including their decimal strings and first sender.

Keep the same invoice, mode and `external_order_id` when retrying an uncertain
outcome. Creation returns 201 and an identical replay returns 200; both yield a
`Paymos::Refund`. Changing the mode under the same key raises
`Paymos::ConflictError` (409). Missing or foreign refund IDs raise
`Paymos::NotFoundError` (404). List periods use RFC 3339 timestamps, and
`paymos.refunds.each` provides the same bounded cursor iteration as invoices.
In sandbox, use `paymos.refunds.simulate(refund.withdrawal_id, status: 'completed')`,
then read the refund again. Refunds have their own list and do not appear in the
ordinary withdrawals list.

A payment channel is one payer's reusable set of deposit addresses. Create it,
read its rails, then poll the confirmed-deposit feed and persist the cursor:

```ruby
channel = paymos.payment_channels.create(project_id: "prj_...", external_id: "customer_42")
channel.networks.each do |rail|
  next if rail.address.nil? # this rail has not provisioned yet

  puts "#{rail.network} #{rail.status} #{rail.address}"
end

feed = paymos.payment_channel_deposits.read(cursor: saved_cursor, limit: 100)
feed.items.each { |deposit| credit_deposit(deposit) } # one credit per deposit.id, see below
save_cursor(feed.next_cursor)
```

Four things that bite a caller who guesses. Repeating the same `external_id`
returns the **same** channel — `200` instead of `201`, and both bodies are a
channel, so calling this on every checkout is safe: a repeat is not a duplicate
and not an error. A rail's `address` is nil until that rail finishes
provisioning and never changes once set, so nil means "not yet", not "no
address". A nil `minimum_deposit` means "we cannot quote a minimum right now",
never "there is no minimum" — reading it as zero is how a merchant accepts a
deposit that lands below the live minimum and is never credited. And
`next_cursor` is never empty, not even on a page with no items: store it and
resume from it, and never loop until it is nil the way `each` ends a list,
because that loop either spins forever or stops on the first quiet page and
leaves reconciliation silently behind. `confirmed_from` is the first poll's
lower bound only; afterwards the stored cursor is the resume mechanism.

API failures raise typed `Paymos::ApiError` subclasses and preserve the status,
problem fields, headers, response body, and `Retry-After`. Cursor helpers are
lazy, bounded, and reject a repeated cursor.

Never expose the API secret in a browser or mobile application. Verify webhook
signatures against the exact raw request body before parsing JSON.

```ruby
event = Paymos::WebhookVerifier.new(ENV.fetch("PAYMOS_WEBHOOK_SECRET"))
  .construct_event(request.env.fetch("HTTP_X_WEBHOOK_SIGNATURE"), request.body.read)
```

Every `payment_channel.deposit.*` event carries a full payment-channel deposit as its
`data`; `data` comes back as a plain Hash, so hand it to `PaymentChannelDeposit.from`
to get the same typed model the deposit feed returns:

```ruby
case event.event_type
when "payment_channel.deposit.confirmed"
  deposit = Paymos::PaymentChannelDeposit.from(event.data)
  credit_deposit(deposit) if deposit.is_final # once per deposit.id, shared with the feed
end
```

The feed and the deposit webhook report the same deposits, so both go through one
`credit_deposit` keyed by the deposit's own `id` (`pcd_...`). A sketch with the `pg` gem
(`credited_deposits.deposit_id` is the primary key):

```ruby
def credit_deposit(deposit)
  return unless deposit.is_final && deposit.project_id == MY_PROJECT_ID && deposit.is_test == MY_IS_TEST

  db.transaction do |tx|
    # The insert and the balance update commit together or not at all. A second
    # delivery, a second endpoint's copy, or a re-read feed page inserts nothing.
    inserted = tx.exec_params(
      'INSERT INTO credited_deposits (deposit_id, payer, amount) VALUES ($1, $2, $3::numeric) '       'ON CONFLICT (deposit_id) DO NOTHING',
      [deposit.id, deposit.payment_channel_external_id, deposit.net]
    )
    if inserted.cmd_tuples == 1
      tx.exec_params('UPDATE balances SET amount = amount + $1::numeric WHERE payer = $2',
                     [deposit.net, deposit.payment_channel_external_id])
    end
  end
end
```

`event.event_id` identifies one delivery, not one payment. Paymos creates a separate
event, with its own `event_id`, for every webhook endpoint subscribed to the event, and
every later event about the same invoice or deposit has its own `event_id` too. Store
`event_id` to skip a redelivered request, but key money and fulfilment on the business
identity: the invoice/order for invoice events, the deposit `id` for deposit events.
Write that key in the same database transaction as the order or balance change.

`confirming` and `reorged` are advisory and may arrive out of order — a `confirming`
can land after the `confirmed` for the same deposit, and a `reorged` can be superseded
by a later `confirmed`. Credit only on `payment_channel.deposit.confirmed` with
`is_final` true, and never let an advisory event regress a deposit you already know is
confirmed: crediting on `confirming` releases goods against money a reorg can still
take back.

Ruby 3.1 or newer is supported. See `conformance/contract.json` for the shared
cross-language protocol contract and https://paymos.io/docs/server-sdks for the
full API guide.

## 401 and 403 are different problems

A **401** means the credential is absent, malformed or unverifiable — fix the key or the signing
clock, and stop retrying.

A **403** means the credential was accepted and something else refused. It covers two very
different situations:

- **the key is wrong for this call** — `payout_key_required`, `payment_key_required`,
  `forbidden`;
- **the key is fine, the account or project state says no** — `whitelist_required`,
  `merchant_suspended`, `widget_inactive`, `terminal_not_enabled`, `not_sandbox`.

A customer entering a payout address that is not whitelisted yet is the second kind: nothing is
wrong with your credentials, and paging the on-call engineer about them is the wrong move. Always
switch on the error `code` before deciding what to do.

`Paymos::PermissionError` subclasses `Paymos::AuthenticationError`, so a `rescue` written before
this split keeps catching 403.
