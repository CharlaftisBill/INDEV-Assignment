#!/usr/bin/env python3
"""Loopback-only TCP forwarder for the external-VM tunnel (scripts/external.sh), like Lima's pseudoloopback.

macOS lets a non-root user bind ports below 1024 only on the wildcard address, so 127.0.0.1:443 is refused.
This binds the wildcard address, drops every connection that does not come from this machine, and pipes
the rest to 127.0.0.1:<to> (an `ssh -L` forward). Binds in the foreground (errors show), then daemonizes.

  loopback-forward.py PIDFILE LOGFILE FROM:TO [FROM:TO ...]
"""
import asyncio
import ipaddress
import os
import socket
import sys


def is_local(peer):
    ip = ipaddress.ip_address(peer[0].split("%")[0])
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_loopback


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
    except OSError:
        pass


def handler(to):
    async def handle(c_reader, c_writer):
        if not is_local(c_writer.get_extra_info("peername")):
            c_writer.close()
            return
        try:
            u_reader, u_writer = await asyncio.open_connection("127.0.0.1", to)
        except OSError:
            c_writer.close()
            return
        await asyncio.gather(pipe(c_reader, u_writer), pipe(u_reader, c_writer))
        for w in (u_writer, c_writer):
            w.close()

    return handle


def listen(port):
    # One dual-stack socket on [::] (IPv4 too), as Lima does; falls back to 0.0.0.0 without IPv6.
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        addr = ("::", port)
    except OSError:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        addr = ("0.0.0.0", port)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(addr)
    s.listen(128)
    return s


async def serve(socks):
    servers = [await asyncio.start_server(handler(to), sock=s) for s, to in socks]
    await asyncio.gather(*(srv.serve_forever() for srv in servers))


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    pidfile, logfile, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
    socks = []
    for pair in pairs:
        frm, to = (int(x) for x in pair.split(":"))
        try:
            socks.append((listen(frm), to))
        except OSError as e:
            sys.exit(f"loopback-forward: cannot listen on port {frm}: {e.strerror}")
    pid = os.fork()
    if pid:  # parent: record the child before returning, so the caller can check it at once
        with open(pidfile, "w") as f:
            f.write(f"{pid}\n")
        os._exit(0)
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    log = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(devnull, 0)
    os.dup2(log, 1)
    os.dup2(log, 2)
    asyncio.run(serve(socks))


if __name__ == "__main__":
    main()
