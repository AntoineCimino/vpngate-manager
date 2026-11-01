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

## Validation

- The original Tailscale-enabled host acceptance check passed on 2026-10-30:
  ordinary curl and connected Chrome reported `IsTor: true`; Tor's relay
  directory confirmed the browser exit country as US. Stop restored original
  Tailscale DNS, resolver contents, per-interface IPv6 values and IPv4 routes.
- The existing independent Tor service remained running: VPNGate selects free
  listener ports and recovers those choices from its saved session config.
- WSL2 notes describe requirements and limitations; this Linux release does not
  claim Windows/WSL2 runtime certification.
