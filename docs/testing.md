# Verification

Validated on Linux on 2026-10-30:

- 83 standard-library regression tests pass, including Bash CLI selection,
  installer helper delivery, Tor DNS transactions/rollback, exact IPv6 restore,
  Cloudflare DNS conflicts/recovery, and existing list/cache regressions.
- Disposable kernel namespaces exercise real veth, routes, iptables, scoped
  cleanup, resource-name collisions, subnet overlap and interrupted setup.
- A local OpenVPN TLS server proves that SOCKS traffic reaches its HTTP endpoint
  with the tunnel peer address. After the tunnel is killed, direct access still
  works and SOCKS access fails closed. Teardown restores routes, firewall rules
  and forwarding settings. The fixture uses no public VPN servers.
- A real NetworkManager daemon in an offline disposable container validates
  D-Bus DNS enable/status/restore. Pending persisted profile edits are not
  applied; independent IP addresses/routes remain unchanged. See the
  [reproducible DNS test](cloudflare-dns.md).
- A real Tor session in a disposable container returns `IsTor: true` through
  ordinary DNS/TCP. A Tailscale CLI/DNS fixture checks preference restoration
  and a second invocation stopping foreground mode. This does not reproduce
  a logged-in Tailscale daemon on the originally affected host.

## Authentication-failure baseline

The previous namespace startup loop had a 60-iteration deadline, sleeping one
second each iteration. It checked for a tunnel or a dead PID but never checked
`AUTH_FAILED`; a rejecting daemon that stayed alive therefore consumed the full
60-second connection deadline. This baseline was identified from the original
source before implementing the fast-fail check.

The new loop inspects authentication/fatal errors before each sleep and uses
OpenVPN's `--auth-retry none`. The kernel regression injects an authentication
rejection and verifies startup **including rollback** finishes within 10 seconds.
This bounds the manager's delay; a caller still controls its own retry schedule.

## Route invariant

The namespace design requires a host veth address and a temporary connected
`10.200.200.0/30` route. Existing routes and the default route are preserved while
it runs; the original IPv4/IPv6 route tables are restored exactly on stop.
Claiming that absolutely no route is added during operation would contradict
this veth design. Tests cover the actual connectivity invariant explicitly.

## Affected-host acceptance

The real Tailscale-enabled host passed an additional acceptance test: ordinary
curl and connected Chrome returned `IsTor: true`, the requested US exit was
confirmed through Tor's relay directory, and stop restored DNS preferences,
resolver contents, per-interface IPv6 values and the IPv4 route set. A fresh
ordinary curl then returned `IsTor: false`. A separate Tor service on its own
listener remained running; free-port selection avoids that conflict.

One request had a transient TLS disconnect before a bounded retry succeeded.
Public exit/checker availability remains outside deterministic regression tests.
WSL2 behavior is not runtime-certified; its notes state Linux-kernel requirements.
Use disposable containers for routine smoke tests to preserve host connectivity.
