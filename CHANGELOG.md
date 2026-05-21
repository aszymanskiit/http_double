# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-05-21

### Fixed

- MockServer `PUT /expectation` responses with `body.type: JSON` now send
  `Content-Type: application/json` (and honour `contentType` when set), so HTTP
  clients such as Req decode JSON bodies instead of leaving them as raw strings.
- Plug adapter no longer duplicates `charset` in `Content-Type` when a full MIME
  type is provided via response headers.

## [1.0.0] - 2026-03-06

### Added

- Initial release of HttpDouble:
  - Real TCP/HTTP/1.1 dummy server implemented in Elixir/OTP.
  - Static routes and mock/expectation engine.
  - Fault injection (timeouts, closes, delays, raw/partial responses).
  - Request history for assertions.
  - ExUnit helper case template.
  - CI configuration, Credo, Dialyzer and documentation.

