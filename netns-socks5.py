#!/usr/bin/env python3
"""Minimal SOCKS5 proxy (CONNECT only, no auth) — stdlib only.

# ponytail: no microsocks/dante/sockd installed on the target host and this
# proxy only ever needs to run inside an isolated netns bound to a single
# veth IP, so a ~100-line stdlib implementation is the smallest safe option
# rather than adding a new apt package. Upgrade to microsocks if UDP ASSOCIATE
# or auth is ever needed.

Usage: netns-socks5.py <bind_ip> <bind_port>
"""
import socket
import struct
import sys
import threading

SOCKS_VERSION = 5


def recv_exact(conn, count):
    """TCP may split every byte of the SOCKS handshake across packets."""
    data = bytearray()
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise OSError("Truncated SOCKS handshake")
        data.extend(chunk)
    return bytes(data)


def handle_client(conn):
    remote = None
    try:
        conn.settimeout(30)
        # Greeting: VER NMETHODS METHODS
        header = recv_exact(conn, 2)
        if len(header) < 2 or header[0] != SOCKS_VERSION:
            return
        nmethods = header[1]
        methods = recv_exact(conn, nmethods)
        if 0 not in methods:
            conn.sendall(b"\x05\xff")
            return
        conn.sendall(bytes([SOCKS_VERSION, 0x00]))  # no auth required

        # Request: VER CMD RSV ATYP DST.ADDR DST.PORT
        req = recv_exact(conn, 4)
        if len(req) < 4 or req[0] != SOCKS_VERSION:
            return
        cmd, atyp = req[1], req[3]

        if atyp == 0x01:  # IPv4
            addr = socket.inet_ntoa(recv_exact(conn, 4))
        elif atyp == 0x03:  # domain name
            length = recv_exact(conn, 1)[0]
            addr = recv_exact(conn, length).decode("ascii")
        elif atyp == 0x04:  # IPv6
            addr = socket.inet_ntop(socket.AF_INET6, recv_exact(conn, 16))
        else:
            return
        port = struct.unpack(">H", recv_exact(conn, 2))[0]

        if cmd != 0x01:  # only CONNECT supported
            conn.sendall(bytes([SOCKS_VERSION, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            return

        try:
            remote = socket.create_connection((addr, port), timeout=15)
        except OSError:
            conn.sendall(bytes([SOCKS_VERSION, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            return

        bind_ip, bind_port = remote.getsockname()[:2]
        atyp = 0x01 if remote.family == socket.AF_INET else 0x04
        reply = bytes([SOCKS_VERSION, 0x00, 0x00, atyp]) + socket.inet_pton(remote.family, bind_ip) \
            + struct.pack(">H", bind_port)
        conn.sendall(reply)

        relay(conn, remote)
    except (OSError, socket.timeout, IndexError, UnicodeDecodeError):
        pass
    finally:
        if remote is not None:
            remote.close()
        conn.close()


def relay(a, b):
    a.settimeout(None)
    b.settimeout(None)

    def pipe(src, dst):
        try:
            while True:
                data = src.recv(8192)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    t1 = threading.Thread(target=pipe, args=(a, b), daemon=True)
    t2 = threading.Thread(target=pipe, args=(b, a), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    a.close()
    b.close()


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <bind_ip> <bind_port>", file=sys.stderr)
        sys.exit(1)
    bind_ip, bind_port = sys.argv[1], int(sys.argv[2])

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((bind_ip, bind_port))
    server.listen(50)
    print(f"netns-socks5 listening on {bind_ip}:{bind_port}", flush=True)

    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle_client, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
