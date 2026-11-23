#!/usr/bin/env python3
"""Allowlisting HTTPS proxy on the host for an air-gapped VM (external-vm.conf egress=host, scripts/external.sh).

The VM has no internet of its own. `ssh -R` maps the VM's 127.0.0.1:<port> to this proxy, and apt, containerd,
helm and get_url on the VM use it. Relayed: `CONNECT <host>:443` (TLS stays end to end) and plain `http://<host>/`
requests on port 80 (apt sources that use http; one request per connection), both only to allowlisted hosts.
Everything else is refused, and every decision is logged. Binds 127.0.0.1 in the foreground
(errors show), then daemonizes.

  egress-proxy.py PIDFILE LOGFILE PORT ALLOWLIST_FILE
Allowlist: one hostname per line; a leading dot matches any subdomain (CDN redirects); `*` allows every host
(only to find what a changed pin needs, from the log). `#` starts a comment.
"""
import asyncio
import os
import socket
import sys
import time
from urllib.parse import urlsplit


def load_allowlist(path):
    exact, suffixes = set(), []
    with open(path) as f:
        for line in f:
            name = line.split("#", 1)[0].strip().lower()
            if name.startswith("."):
                suffixes.append(name)
            elif name:
                exact.add(name)
    return exact, tuple(suffixes)


def log(msg):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
    except OSError:
        pass


def handler(path):
    rules = {"mtime": None, "exact": set(), "suffixes": ()}

    def allowed(host):
        # Reloaded when the file changes, so a missing host can be added without restarting the tunnel.
        try:
            mtime = os.stat(path).st_mtime
            if mtime != rules["mtime"]:
                rules["exact"], rules["suffixes"] = load_allowlist(path)
                rules["mtime"] = mtime
                log(f"allowlist loaded: {len(rules['exact'])} hosts, {len(rules['suffixes'])} suffixes")
        except OSError as e:
            log(f"allowlist unreadable, keeping the last one: {e}")
        exact, suffixes = rules["exact"], rules["suffixes"]
        return "*" in exact or host in exact or host.endswith(suffixes)

    async def handle(c_reader, c_writer):
        async def reply(status):
            c_writer.write(f"HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
            try:
                await c_writer.drain()
            except OSError:
                pass
            c_writer.close()

        try:
            head = await asyncio.wait_for(c_reader.readuntil(b"\r\n\r\n"), 30)
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, OSError):
            c_writer.close()
            return
        # B-066: only CRLF line ends and no control bytes (TAB aside): a bare LF would let a server see a header,
        # such as a second Host, that the filters below never saw.
        body = head[:-4].replace(b"\r\n", b"")
        if any(c < 0x20 and c != 0x09 or c == 0x7F for c in body):
            log("DENY  request head with a bare CR/LF or control byte")
            return await reply("400 Bad Request")
        lines = head.decode("latin-1").split("\r\n")
        parts = lines[0].split()
        if len(parts) != 3:
            return await reply("400 Bad Request")
        if parts[0] != "CONNECT":
            return await plain_http(parts, lines[1:], c_reader, c_writer, reply)
        host, _, port = parts[1].rpartition(":")
        host = host.strip("[]").lower()
        if port != "443" or not allowed(host):
            log(f"DENY  {host}:{port} (not on the allowlist)")
            return await reply("403 Forbidden")
        try:
            u_reader, u_writer = await asyncio.wait_for(asyncio.open_connection(host, 443), 30)
        except (OSError, asyncio.TimeoutError) as e:
            log(f"FAIL  {host}:443 ({e})")
            return await reply("502 Bad Gateway")
        log(f"ALLOW {host}:443")
        c_writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await asyncio.gather(pipe(c_reader, u_writer), pipe(u_reader, c_writer))
        for w in (u_writer, c_writer):
            w.close()

    async def plain_http(parts, headers, c_reader, c_writer, reply):
        method, target, version = parts
        try:
            url = urlsplit(target)
            host = (url.hostname or "").lower()
            port = url.port or 80
        except ValueError:  # bad port or URL
            log(f"DENY  {method} (malformed URL)")
            return await reply("400 Bad Request")
        if url.scheme != "http" or port != 80 or not allowed(host):
            log(f"DENY  {method} {url.scheme}://{host}:{port} (only allowlisted http on port 80)")
            return await reply("403 Forbidden")
        try:
            u_reader, u_writer = await asyncio.wait_for(asyncio.open_connection(host, 80), 30)
        except (OSError, asyncio.TimeoutError) as e:
            log(f"FAIL  {host}:80 ({e})")
            return await reply("502 Bad Gateway")
        log(f"ALLOW {method} http://{host}")
        # Origin-form request line; hop-by-hop headers dropped; one request per connection keeps hosts apart.
        # Host is always the checked one (B-066): a CDN routes on it, so the client's own would reach other tenants.
        # Folded lines (leading whitespace) are dropped too, so nothing can continue a header past this filter.
        def keep(h):
            name = h.split(":", 1)[0].strip().lower()
            return h and not h[0].isspace() and name not in ("host", "connection", "keep-alive") and not name.startswith("proxy-")
        kept = [f"Host: {host}"] + [h for h in headers if keep(h)]
        path = url.path or "/"
        if url.query:
            path += "?" + url.query
        u_writer.write(("\r\n".join([f"{method} {path} {version}", *kept, "Connection: close", "", ""])).encode("latin-1"))
        await asyncio.gather(pipe(c_reader, u_writer), pipe(u_reader, c_writer))
        for w in (u_writer, c_writer):
            w.close()

    return handle


async def serve(sock, path):
    srv = await asyncio.start_server(handler(path), sock=sock)
    await srv.serve_forever()


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    pidfile, logfile, port, allowlist = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    load_allowlist(allowlist)  # fail now, in the foreground, if it is unreadable
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError as e:
        sys.exit(f"egress-proxy: cannot listen on 127.0.0.1:{port}: {e.strerror}")
    sock.listen(128)
    pid = os.fork()
    if pid:  # parent: record the child before returning, so the caller can check it at once
        with open(pidfile, "w") as f:
            f.write(f"{pid}\n")
        os._exit(0)
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    out = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(devnull, 0)
    os.dup2(out, 1)
    os.dup2(out, 2)
    log(f"listening on 127.0.0.1:{port}")
    asyncio.run(serve(sock, allowlist))


if __name__ == "__main__":
    main()
