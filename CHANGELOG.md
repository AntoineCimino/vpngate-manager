## Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Harden isolated VPN setup/teardown with a tunnel kill switch, scoped process
  cleanup, resource ownership tracking, rollback, subnet conflict checks and
  restoration of forwarding settings. Ship the SOCKS helper in all installs.
- Fail immediately on `AUTH_FAILED`, replacing the previous 60-second wait.
- Preserve Tailscale DNS and per-interface IPv6 settings around Tor sessions;
  use a dedicated Tor account, validate the transparent path, and retain failed
  cleanup state for recovery.
- Add optional Cloudflare DNS benchmarking and reversible NetworkManager DNS
  controls that preserve applied network configuration and reject conflicts.
- Add `start --auto`, `local --file`, `VPNGATE_DATA_DIR`, safe `purge`, Windows
  compatibility notes, regression tests and GitHub Actions.
- Use HTTPS for VPNGate list downloads.


- Added `tor <country_code>` command: routes traffic through a country-specific Tor exit node
  when VPNGate has no server in that region, with environment validation (tor/iptables presence,
  iptables compatibility, exit relay availability), an isolated `VPNGATE_TOR` iptables chain,
  and mutual exclusivity with OpenVPN mode.
- `status` now reports the active mode (OpenVPN, Tor, or none) and Tor-specific details
  (requested country, bootstrap status, exit IP) when relevant.
- Docs and repository hygiene improvements.

