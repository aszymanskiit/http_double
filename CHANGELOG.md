# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-06

### Added

- Initial release of HttpDouble:
  - Real TCP/HTTP/1.1 dummy server implemented in Elixir/OTP.
  - Static routes and mock/expectation engine.
  - Fault injection (timeouts, closes, delays, raw/partial responses).
  - Request history for assertions.
  - ExUnit helper case template.
  - CI configuration, Credo, Dialyzer and documentation.

