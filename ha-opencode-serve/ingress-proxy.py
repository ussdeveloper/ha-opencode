#!/usr/bin/env python3
"""Proxy OpenCode serve into a Home Assistant ingress iframe.

Supervisor strips /api/hassio_ingress/<token> before the request reaches this
process and sends that prefix in X-Ingress-Path. OpenCode 2.2 serves the web
UI at / and calls APIs on location.origin, so a bare reverse proxy breaks the
sidebar. This proxy:

- rewrites absolute asset URLs in HTML
- injects a script that hides the ingress prefix from the client router and
  puts it back on fetch, WebSocket, XHR, and media URLs
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from typing import Optional

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-connection",
    "transfer-encoding",
    "upgrade",
    "te",
    "trailer",
}

INJECT_JS = r"""
<script nonce="__NONCE__">
(function () {
  var P = __PREFIX__;
  if (!P) return;
  if (P.charAt(P.length - 1) === "/") P = P.slice(0, -1);

  function already(path) {
    return path === P || path.indexOf(P + "/") === 0;
  }

  function prefixPath(path) {
    if (!path || path.charAt(0) !== "/") return path;
    if (already(path)) return path;
    return P + path;
  }

  function rewriteHistoryUrl(url) {
    if (url == null) return url;
    try {
      var abs = new URL(String(url), location.href);
      if (abs.origin !== location.origin) return url;
      if (already(abs.pathname)) return url;
      abs.pathname = prefixPath(abs.pathname);
      return abs.pathname + abs.search + abs.hash;
    } catch (e) {
      return url;
    }
  }

  function fix(u) {
    if (u == null) return u;
    var s = typeof u === "string" ? u : (u && u.url) || String(u);
    try {
      var abs = new URL(s, location.href);
      if (abs.origin !== location.origin || already(abs.pathname)) return u;
      abs.pathname = prefixPath(abs.pathname);
      return abs.toString();
    } catch (e) {
      return u;
    }
  }

  try {
    var desc = Object.getOwnPropertyDescriptor(Location.prototype, "pathname");
    if (desc && desc.get && desc.configurable) {
      Object.defineProperty(Location.prototype, "pathname", {
        configurable: true,
        enumerable: desc.enumerable,
        get: function () {
          var value = desc.get.call(this);
          if (this === location && already(value)) {
            var rest = value.slice(P.length);
            return rest.charAt(0) === "/" ? rest : "/" + rest;
          }
          return value;
        },
        set: function (value) {
          var next = String(value);
          if (this === location) next = prefixPath(next.charAt(0) === "/" ? next : "/" + next);
          return desc.set.call(this, next);
        },
      });
    }
  } catch (e) {}

  function wrapHistory(name) {
    var orig = History.prototype[name];
    History.prototype[name] = function (state, title, url) {
      return orig.call(this, state, title, rewriteHistoryUrl(url));
    };
  }
  wrapHistory("pushState");
  wrapHistory("replaceState");

  ["assign", "replace"].forEach(function (name) {
    var orig = Location.prototype[name];
    if (!orig) return;
    Location.prototype[name] = function (url) {
      return orig.call(this, rewriteHistoryUrl(url));
    };
  });

  var ofetch = window.fetch;
  window.fetch = function (input, init) {
    try {
      if (typeof input === "string") input = fix(input);
      else if (input && typeof input.url === "string") input = new Request(fix(input.url), input);
    } catch (e) {}
    return ofetch.call(this, input, init);
  };

  var OW = window.WebSocket;
  function WrappedWebSocket(url, protocols) {
    var fixed = fix(url);
    return protocols === undefined ? new OW(fixed) : new OW(fixed, protocols);
  }
  WrappedWebSocket.prototype = OW.prototype;
  WrappedWebSocket.CONNECTING = OW.CONNECTING;
  WrappedWebSocket.OPEN = OW.OPEN;
  WrappedWebSocket.CLOSING = OW.CLOSING;
  WrappedWebSocket.CLOSED = OW.CLOSED;
  window.WebSocket = WrappedWebSocket;

  if (window.EventSource) {
    var OE = window.EventSource;
    var WrappedEventSource = function (url, cfg) { return new OE(fix(url), cfg); };
    WrappedEventSource.prototype = OE.prototype;
    window.EventSource = WrappedEventSource;
  }

  var xo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    var args = Array.prototype.slice.call(arguments);
    args[1] = fix(url);
    return xo.apply(this, args);
  };

  function patchProp(proto, prop) {
    var d = Object.getOwnPropertyDescriptor(proto, prop);
    if (!d || !d.set || !d.configurable) return;
    Object.defineProperty(proto, prop, {
      configurable: true,
      enumerable: d.enumerable,
      get: d.get,
      set: function (value) { return d.set.call(this, fix(value)); },
    });
  }
  if (window.HTMLImageElement) patchProp(HTMLImageElement.prototype, "src");
  if (window.HTMLScriptElement) patchProp(HTMLScriptElement.prototype, "src");
  if (window.HTMLLinkElement) patchProp(HTMLLinkElement.prototype, "href");
  if (window.HTMLMediaElement) patchProp(HTMLMediaElement.prototype, "src");

  var setAttr = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if ((name === "src" || name === "href") && typeof value === "string") value = fix(value);
    return setAttr.call(this, name, value);
  };

  if (navigator.serviceWorker && navigator.serviceWorker.register) {
    navigator.serviceWorker.register = function () { return Promise.resolve(); };
  }

  window.__OPENCODE__ = window.__OPENCODE__ || {};
  window.__OPENCODE__.basePath = P;
})();
</script>
"""


def normalize_prefix(value: str) -> str:
    prefix = (value or "").strip()
    if not prefix:
        return ""
    if not prefix.startswith("/"):
        prefix = "/" + prefix
    return prefix.rstrip("/")


def rewrite_set_cookie(value: str, prefix: str) -> str:
    if not prefix:
        return value

    def repl(match: re.Match[str]) -> str:
        return f"{match.group(1)}{prefix}/"

    return re.sub(r"(?i)(Path=)/(?=$|;)", repl, value)


def rewrite_location(value: str, prefix: str) -> str:
    if not prefix or not value.startswith("/") or value.startswith("//"):
        return value
    if value == prefix or value.startswith(prefix + "/"):
        return value
    return prefix + value


_ATTR_RE = re.compile(r"""(?P<attr>href|src|action)=(?P<q>["'])(?P<path>/[^"']*)(?P=q)""", re.I)


def rewrite_html(html: str, prefix: str, nonce: str) -> str:
    if not prefix:
        return html

    def repl(match: re.Match[str]) -> str:
        path = match.group("path")
        if path.startswith("//") or path == prefix or path.startswith(prefix + "/"):
            return match.group(0)
        quote = match.group("q")
        return f"{match.group('attr')}={quote}{prefix}{path}{quote}"

    html = _ATTR_RE.sub(repl, html)
    script = INJECT_JS.replace("__PREFIX__", json.dumps(prefix)).replace("__NONCE__", nonce)
    head = re.search(r"<head[^>]*>", html, flags=re.I)
    if head:
        at = head.end()
        return html[:at] + script + html[at:]
    return script + html


def nonce_from(headers: dict[str, str], body: str) -> str:
    csp = headers.get("content-security-policy", "")
    match = re.search(r"nonce-([A-Za-z0-9+/=_-]+)", csp)
    if match:
        return match.group(1)
    match = re.search(r"""nonce=["']([^"']+)["']""", body)
    return match.group(1) if match else ""


def relax_csp(value: str) -> str:
    if not value or "unsafe-inline" in value or "nonce-" in value:
        return value

    def add(match: re.Match[str]) -> str:
        return match.group(0) + " 'unsafe-inline'"

    updated, count = re.subn(r"(?i)script-src(?:-elem)?[^;]*", add, value)
    return updated if count else value


class HttpMessage:
    def __init__(self, start: str, headers: dict[str, str], raw_headers: list[tuple[str, str]], body: bytes):
        self.start = start
        self.headers = headers
        self.raw_headers = raw_headers
        self.body = body

    @property
    def upgrade(self) -> bool:
        connection = self.headers.get("connection", "")
        return "upgrade" in connection.lower() or "websocket" in self.headers.get("upgrade", "").lower()


async def _read_headers(reader: asyncio.StreamReader) -> Optional[tuple[str, dict[str, str], list[tuple[str, str]]]]:
    try:
        start = await reader.readuntil(b"\r\n")
    except asyncio.IncompleteReadError:
        return None
    if not start or start == b"\r\n":
        return None
    raw: list[tuple[str, str]] = []
    folded: dict[str, str] = {}
    while True:
        line = await reader.readuntil(b"\r\n")
        if line in (b"\r\n", b"\n"):
            break
        text = line.decode("iso-8859-1").strip("\r\n")
        if ":" not in text:
            continue
        name, value = text.split(":", 1)
        raw.append((name, value.strip()))
        key = name.lower()
        folded[key] = value.strip() if key not in folded else folded[key] + ", " + value.strip()
    return start.decode("iso-8859-1").strip("\r\n"), folded, raw


async def _read_body(reader: asyncio.StreamReader, headers: dict[str, str]) -> bytes:
    if headers.get("transfer-encoding", "").lower().find("chunked") != -1:
        chunks: list[bytes] = []
        while True:
            size_line = await reader.readuntil(b"\r\n")
            size = int(size_line.split(b";", 1)[0].strip(), 16)
            if size == 0:
                await reader.readuntil(b"\r\n")
                break
            data = await reader.readexactly(size)
            await reader.readexactly(2)
            chunks.append(data)
        return b"".join(chunks)
    length = headers.get("content-length")
    if length is None:
        return b""
    return await reader.readexactly(int(length))


async def read_http(reader: asyncio.StreamReader, read_until_eof: bool = False) -> Optional[HttpMessage]:
    parsed = await _read_headers(reader)
    if parsed is None:
        return None
    start, headers, raw = parsed
    if (
        read_until_eof
        and "content-length" not in headers
        and "chunked" not in headers.get("transfer-encoding", "").lower()
    ):
        body = await reader.read()
    else:
        body = await _read_body(reader, headers)
    return HttpMessage(start, headers, raw, body)


def encode_request(message: HttpMessage, upstream_host: str) -> bytes:
    lines = [message.start]
    for name, value in message.raw_headers:
        key = name.lower()
        if key == "host":
            continue
        if not message.upgrade and key in HOP_BY_HOP:
            continue
        lines.append(f"{name}: {value}")
    lines.append(f"Host: {upstream_host}")
    if not message.upgrade:
        lines.append("Connection: close")
        if message.body:
            lines.append(f"Content-Length: {len(message.body)}")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1") + message.body


def encode_response(start: str, raw_headers: list[tuple[str, str]], body: bytes, prefix: str, content_type: str) -> bytes:
    lines = [start]
    for name, value in raw_headers:
        key = name.lower()
        if key in HOP_BY_HOP or key == "content-length":
            continue
        if key == "location":
            value = rewrite_location(value, prefix)
        elif key == "set-cookie":
            value = rewrite_set_cookie(value, prefix)
        elif key == "content-security-policy":
            value = relax_csp(value)
        lines.append(f"{name}: {value}")
    if "text/html" in content_type:
        lines.append(f"Content-Length: {len(body)}")
    else:
        lines.append(f"Content-Length: {len(body)}")
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1") + body


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def make_handler(upstream_host: str, upstream_port: int):
    async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
        try:
            request = await read_http(client_reader)
            if request is None:
                return
            prefix = normalize_prefix(request.headers.get("x-ingress-path", ""))
            try:
                upstream_reader, upstream_writer = await asyncio.open_connection(upstream_host, upstream_port)
            except OSError as exc:
                body = f"OpenCode upstream unavailable: {exc}\n".encode()
                client_writer.write(
                    b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: "
                    + str(len(body)).encode()
                    + b"\r\nConnection: close\r\n\r\n"
                    + body
                )
                await client_writer.drain()
                return

            host_header = f"{upstream_host}:{upstream_port}"
            upstream_writer.write(encode_request(request, host_header))
            await upstream_writer.drain()

            if request.upgrade:
                await asyncio.gather(
                    pipe(client_reader, upstream_writer),
                    pipe(upstream_reader, client_writer),
                )
                return

            response = await read_http(upstream_reader, read_until_eof=True)
            if response is None:
                return
            content_type = response.headers.get("content-type", "")
            body = response.body
            if "text/html" in content_type.lower() and body:
                text = body.decode("utf-8", errors="replace")
                nonce = nonce_from(response.headers, text)
                text = rewrite_html(text, prefix, nonce)
                body = text.encode("utf-8")
            client_writer.write(encode_response(response.start, response.raw_headers, body, prefix, content_type))
            await client_writer.drain()
            upstream_writer.close()
        except (asyncio.IncompleteReadError, ConnectionError, asyncio.TimeoutError):
            pass
        finally:
            try:
                client_writer.close()
                await client_writer.wait_closed()
            except Exception:
                pass

    return handle


async def serve(listen_host: str, listen_port: int, upstream_host: str, upstream_port: int) -> None:
    server = await asyncio.start_server(make_handler(upstream_host, upstream_port), listen_host, listen_port)
    sockets = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    print(f"[INFO] Ingress proxy listening on {sockets} -> {upstream_host}:{upstream_port}", flush=True)
    async with server:
        await server.serve_forever()


def self_test() -> None:
    sample = '<head><script src="/_assets/app.js"></script><a href="/settings">x</a></head>'
    rewritten = rewrite_html(sample, "/api/hassio_ingress/abc", "n1")
    assert "/api/hassio_ingress/abc/_assets/app.js" in rewritten, rewritten
    assert "/api/hassio_ingress/abc/settings" in rewritten, rewritten
    assert 'nonce="n1"' in rewritten
    assert rewrite_location("/session/1", "/api/hassio_ingress/abc") == "/api/hassio_ingress/abc/session/1"
    assert rewrite_set_cookie("sid=1; Path=/; HttpOnly", "/api/hassio_ingress/abc").endswith("Path=/api/hassio_ingress/abc/; HttpOnly") or "Path=/api/hassio_ingress/abc/" in rewrite_set_cookie(
        "sid=1; Path=/; HttpOnly", "/api/hassio_ingress/abc"
    )
    assert normalize_prefix("/api/hassio_ingress/abc/") == "/api/hassio_ingress/abc"

    async def scenario() -> None:
        events: asyncio.Queue[bytes] = asyncio.Queue()

        async def upstream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            message = await read_http(reader)
            assert message is not None
            body = b"<head><script src=\"/_assets/app.js\"></script></head>"
            payload = (
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
                + str(len(body)).encode()
                + b"\r\nSet-Cookie: sid=1; Path=/\r\nConnection: close\r\n\r\n"
                + body
            )
            writer.write(payload)
            await writer.drain()
            writer.close()

        upstream_server = await asyncio.start_server(upstream, "127.0.0.1", 0)
        upstream_port = upstream_server.sockets[0].getsockname()[1]
        proxy = await asyncio.start_server(make_handler("127.0.0.1", upstream_port), "127.0.0.1", 0)
        proxy_port = proxy.sockets[0].getsockname()[1]
        reader, writer = await asyncio.open_connection("127.0.0.1", proxy_port)
        req = (
            "GET / HTTP/1.1\r\n"
            "Host: ha.local\r\n"
            "X-Ingress-Path: /api/hassio_ingress/abc\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        writer.write(req)
        await writer.drain()
        data = await reader.read(-1)
        text = data.decode("utf-8", errors="replace")
        assert "/api/hassio_ingress/abc/_assets/app.js" in text, text
        assert "Path=/api/hassio_ingress/abc/" in text, text
        assert "Location.prototype" in text
        writer.close()
        proxy.close()
        upstream_server.close()
        await proxy.wait_closed()
        await upstream_server.wait_closed()
        await events.put(b"ok")

    asyncio.run(scenario())
    print("ingress-proxy self-test ok")


def main() -> None:
    if "--self-test" in sys.argv:
        self_test()
        return
    listen_port = int(os.environ.get("INGRESS_PORT", "4096"))
    upstream_port = int(os.environ.get("OPENCODE_UPSTREAM_PORT", "4097"))
    upstream_host = os.environ.get("OPENCODE_UPSTREAM_HOST", "127.0.0.1")
    asyncio.run(serve("0.0.0.0", listen_port, upstream_host, upstream_port))


if __name__ == "__main__":
    main()
