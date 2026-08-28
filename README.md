# Paymos Ruby SDK

Official Ruby client for the Paymos Merchant API — invoices, withdrawals, balances,
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

Responses are immutable Ruby objects with documented RBS signatures; request
keywords remain idiomatic `snake_case` and are converted directly to the Paymos
wire contract.

A payment channel is one payer's reusable set of deposit addresses. Create it,
read its rails, then poll the confirmed-deposit feed and persist the cursor:

```ruby
channel = paymos.payment_channels.create(project_id: "prj_...", external_id: "customer_42")
channel.networks.each do |rail|
  next if rail.address.nil? # this rail has not provisioned yet

  puts "#{rail.network} #{rail.status} #{rail.address}"
end

feed = paymos.payment_channel_deposits.read(cursor: saved_cursor, limit: 100)
feed.items.each { |deposit| credit(deposit) }
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
  credit(deposit.payment_channel_external_id, deposit.net) if deposit.is_final
end
```

`confirming` and `reorged` are advisory and may arrive out of order — a `confirming`
can land after the `confirmed` for the same deposit, and a `reorged` can be superseded
by a later `confirmed`. Credit only on `payment_channel.deposit.confirmed` with
`is_final` true, and never let an advisory event regress a deposit you already know is
confirmed: crediting on `confirming` releases goods against money a reorg can still
take back.

Ruby 3.1 or newer is supported. See `conformance/contract.json` for the shared
cross-language protocol contract and https://paymos.io/docs/server-sdks for the
full API guide.
