# Changelog

## [Unreleased]

## [1.5.1] - 2026-11-01

- refactor(invoices): remove the multiple-payment toggle

- **403 is no longer reported as an authentication failure.** `Paymos::PermissionError` (subclasses `Paymos::AuthenticationError`, so existing `rescue` blocks keep working) now carries every 403.
- **Base URL must use HTTPS.** Plain HTTP is accepted only against a loopback host, which is what a local integration test points at. The API secret signs every request, so a plaintext base URL put that credential on the wire.

## [1.5.0] - 2026-10-30

- fix(plugins): reject invalid Woo refund controls and unblock SDK checks
- fix(sdk): preserve current refund contracts in TON conformance
- fix(ton): return friendly addresses with existing webhook schema
- feat(sdk-ruby): add refund create, list and get

- **403 is no longer reported as an authentication failure.** `Paymos::PermissionError` (subclasses `Paymos::AuthenticationError`, so existing `rescue` blocks keep working) now carries every 403.
- **Base URL must use HTTPS.** Plain HTTP is accepted only against a loopback host, which is what a local integration test points at. The API secret signs every request, so a plaintext base URL put that credential on the wire.

## [1.4.0] - 2026-10-30

- fix(plugins): reject invalid Woo refund controls and unblock SDK checks
- fix(sdk): preserve current refund contracts in TON conformance
- fix(ton): return friendly addresses with existing webhook schema
- feat(sdk-ruby): add refund create, list and get

- **403 is no longer reported as an authentication failure.** `Paymos::PermissionError` (subclasses `Paymos::AuthenticationError`, so existing `rescue` blocks keep working) now carries every 403.
- **Base URL must use HTTPS.** Plain HTTP is accepted only against a loopback host, which is what a local integration test points at. The API secret signs every request, so a plaintext base URL put that credential on the wire.

## [1.3.0] - 2026-10-14

- Make the SDK CI tier green
- Fix invoice-late-payment audit findings (tasks 4.1-4.8)
- feat(invoices): accept full late payments without reopening invoices
- fix(sdk-conformance): восемь копий контракта разошлись с каноном — 403 снова permission
- fix(sdk): HTTPS обязателен, а 403 перестал притворяться ошибкой ключа

- **403 is no longer reported as an authentication failure.** `Paymos::PermissionError` (subclasses `Paymos::AuthenticationError`, so existing `rescue` blocks keep working) now carries every 403.
- **Base URL must use HTTPS.** Plain HTTP is accepted only against a loopback host, which is what a local integration test points at. The API secret signs every request, so a plaintext base URL put that credential on the wire.

## [1.2.0] - 2026-08-28

- release: the changelog rot had a cause, and it was not the one I named
- audit: the shipped plugin and SDK docs described a product we stopped shipping
- docs(sdk): the READMEs say static wallets, not payment channels
- feat(sdk): payment-channel webhooks and the flow in every README
- feat(ruby-sdk): payment channels, and a feed reader that cannot stop early
- feat(sdk-conformance): declare the payment-channel operations
- docs(api): pin the empty-body signing rule and fix the published POST vector

## [1.1.1] - 2026-08-02

- fix(ecosystem): recover SDK releases

## [1.1.0] - 2026-07-21

- feat(docs): make the developer surface consumable by LLM agents

## [1.0.4] - 2026-07-19

- fix: align SDK problem details semantics

## [1.0.3] - 2026-07-12

- fix(ruby-sdk): make user agent assertion version aware

## [1.0.2] - 2026-07-12

- fix(release): align Ruby metadata and retry npm publication

## [1.0.1] - 2026-07-12

- fix(sdk): harden Java and Ruby package validation

## 1.0.0 - 2026-07-11

- Initial official Paymos Ruby SDK.
- Covers invoices, withdrawals, balances, system time, cursor pagination, and webhooks.
