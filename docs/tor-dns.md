# Tor mode with Tailscale DNS

Tailscale can install its MagicDNS resolver at `100.100.100.100` and
`fd7a:115c:a1e0::53`. Transparent Tor DNS redirection can conflict with that
host-local resolver path. For an explicit Tor session, VPNGate Manager
can temporarily release Tailscale's DNS management using
`tailscale set --accept-dns=false`. This changes only that preference;
it does not disconnect Tailscale or reset other Tailscale settings.

MagicDNS names and private split DNS may be unavailable to normal applications
until Tor stops. Tailscale itself can still resolve its own names in some
commands; this is not a guarantee that ordinary applications retain private DNS.
Use the namespace mode when automated work must preserve the host's DNS.

The helper saves the original enabled preference **before** changing it,
checks that the daemon accepted the change, and restores it when Tor stops or
startup fails. If DNS acceptance was already disabled, it stays disabled.
A machine without Tailscale needs no DNS change. If Tailscale is installed but
its preferences cannot be read, startup fails without guessing the old setting.
If restoring fails, the state is retained so `stop` can retry later; do not
delete the recovery record until restoration succeeds.

## Helper integration

`tor-dns.py prepare STATE` and `tor-dns.py restore STATE` are internal lifecycle
commands. Invoke with sufficient privileges to change the Tailscale preference,
using the **same persistent state path** in both commands, for example
`$DATA_DIR/tor-dns.json`. The helper requires Python 3 and only its standard
library. It never edits `/etc/resolv.conf`.

The caller must:

1. Validate other prerequisites and finish user confirmation before `prepare`.
2. Abort Tor startup if `prepare` fails.
3. Run `restore` after removing the transparent-proxy rules on every failed
   startup, interrupted startup, normal stop, and repeated stop. This includes
   failures before a Tor PID file exists.
4. Retain the Tor recovery marker when `restore` fails and report the retry
   command; do not print that cleanup succeeded.
5. Serialize the complete Tor lifecycle, in addition to the helper's short
   operation lock. The helper lock prevents competing DNS mutations but does
   not protect the daemon/firewall setup that surrounds it.

## Verification and limits

The regression tests use a fake Tailscale daemon to cover original enabled and
disabled preferences, repeated prepare/restore, unavailable or malformed
preferences, an error after a partial setting change, rollback failures,
recovery retries, state symlinks, and overlapping operations. They do not change
the developer machine's settings.

A live disposable Ubuntu container smoke test on 2026-10-30 confirmed ordinary
DNS/TCP routing through a real Tor exit (`IsTor: true`), successful separate
`stop` during foreground mode, and exact route/firewall restoration. A local
Tailscale CLI/DNS fixture also confirmed enabled → disabled → restored DNS
preferences through that real Tor session. This fixture is not a logged-in
Tailscale daemon. Reproduce it with the Docker command in the README.

The original affected-host acceptance check also passed on 2026-10-30 with
Tailscale DNS enabled before the test. Both ordinary curl and the connected
Chrome browser reported `IsTor: true`, and Tor's public relay directory
confirmed the browser exit was in the requested US country. Startup temporarily
released Tailscale DNS; stop restored the original DNS preference, resolver file,
every captured IPv6 setting and the IPv4 route set. A fresh ordinary curl after
stop reported `IsTor: false`. The kernel-level explanation of the original
MagicDNS interaction remains a hypothesis; the functional acceptance is now
verified on that host.

An independent Tor service already occupied the usual SOCKS port. VPNGate now
selects free ports from SOCKS 9050–9059, TransPort 9040–9049 and DNS 5353–5362,
without stopping that service. Later status/cleanup use the session's saved
runtime; a partial config never prevents DNS/IPv6 recovery.

One standalone request encountered a transient TLS disconnect; bounded curl
retries succeeded. Public Tor exits and checkers can reject individual requests.
The startup check fails closed and rolls back when it cannot confirm the
transparent path. Tor still does not transparently proxy arbitrary UDP traffic.

Sources:

- [Tailscale client preferences](https://tailscale.com/docs/features/client/manage-preferences)
- [Tailscale and resolv.conf](https://tailscale.com/docs/reference/faq/dns-resolv-conf)
- [Tailscale preference definition (`CorpDNS`)](https://github.com/tailscale/tailscale/blob/main/ipn/prefs.go)
