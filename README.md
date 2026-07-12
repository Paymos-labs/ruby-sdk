# Paymos Ruby SDK

Official Ruby client for the Paymos Merchant API. Its only runtime dependency is
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

API failures raise typed `Paymos::ApiError` subclasses and preserve the status,
problem fields, headers, response body, and `Retry-After`. Cursor helpers are
lazy, bounded, and reject a repeated cursor.

Never expose the API secret in a browser or mobile application. Verify webhook
signatures against the exact raw request body before parsing JSON.

```ruby
event = Paymos::WebhookVerifier.new(ENV.fetch("PAYMOS_WEBHOOK_SECRET"))
  .construct_event(request.env.fetch("HTTP_PAYMOS_SIGNATURE"), request.body.read)
```

Ruby 3.1 or newer is supported. See `conformance/contract.json` for the shared
cross-language protocol contract and https://paymos.io/docs/server-sdks for the
full API guide.
