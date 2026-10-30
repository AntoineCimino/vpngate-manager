## Roadmap

- [x] Add dependency checks (Tor/iptables validation)
- [x] Add non-interactive mode (`start --auto`, `local --file`, `netns-start`, `exec`)
- [x] Add data/config directory override (`VPNGATE_DATA_DIR`)
- [x] Add install script (including Python helpers)
- [x] Add Windows notes (WSL2 requirements, WSL1/Git Bash limitations)
- [x] Add purge command (refuses active sessions and recovery state)
- [x] VPNGATE-003: isolate VPN namespace lifecycle and block egress after tunnel loss
- [x] Authentication retries: fail on `AUTH_FAILED` within 10 seconds
- [x] VPNGATE-007: benchmark and optionally use reversible Cloudflare DNS
- [x] VPNGATE-002: implement Tor/Tailscale DNS restoration and transparent-path checks

## Validation still required

- Reproduce the originally reported Tor/MagicDNS interaction on the affected
  Tailscale-enabled host. Helpers and rollback have automated regression tests;
  transparent Tor routing has a live disposable-container smoke test. A SOCKS
  success alone does not establish that the original host-specific issue is fixed.
- Validate WSL2 on an actual Windows host; the compatibility notes state requirements,
  not a tested Windows release claim.
