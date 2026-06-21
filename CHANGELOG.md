## Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Added `tor <country_code>` command: routes traffic through a country-specific Tor exit node
  when VPNGate has no server in that region, with environment validation (tor/iptables presence,
  iptables compatibility, exit relay availability), an isolated `VPNGATE_TOR` iptables chain,
  and mutual exclusivity with OpenVPN mode.
- `status` now reports the active mode (OpenVPN, Tor, or none) and Tor-specific details
  (requested country, bootstrap status, exit IP) when relevant.
- Docs and repository hygiene improvements.

