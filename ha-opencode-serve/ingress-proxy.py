#!/usr/bin/env python3
"""Put OpenCode serve behind Home Assistant ingress.

Supervisor strips /api/hassio_ingress/<token> and sends that prefix in
X-Ingress-Path. OpenCode serves the UI at / and its script URLs are absolute,
so the sidebar iframe would request them from Home Assistant itself.

Only HTML and JavaScript are rewritten. Everything else, including websocket
upgrades, is copied through unchanged. Rewritten bodies are sent without the
original Content-Encoding, because changing a compressed body and leaving that
header in place makes Supervisor report a bad gateway.
"""

from __future__ import annotations

import asyncio
import base64
import gzip
import hashlib
import json
import os
import re
import sys
import zlib
from typing import Optional

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

INJECT_JS = r"""
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

  globalThis.__ocPath = function (input) {
    var path = typeof input === "string" ? input : (location.pathname || "/");
    if (path === P || path === P + "/") return "/";
    if (path.indexOf(P + "/") === 0) {
      var rest = path.slice(P.length);
      return rest.charAt(0) === "/" ? rest : "/" + rest;
    }
    return path;
  };

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
  if (window.HTMLLinkElement) patchProp(HTMLLinkElement.prototype, "href");
  if (window.HTMLScriptElement) patchProp(HTMLScriptElement.prototype, "src");
  if (window.HTMLImageElement) patchProp(HTMLImageElement.prototype, "src");

  var setAttr = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if ((name === "src" || name === "href" || name === "action") && typeof value === "string") value = fix(value);
    return setAttr.call(this, name, value);
  };

  if (navigator.serviceWorker && navigator.serviceWorker.register) {
    navigator.serviceWorker.register = function () { return Promise.resolve(); };
  }
})();
"""

_ATTR_RE = re.compile(
    r"""(?P<attr>href|src|action)=(?P<q>["'])(?P<path>/[^"']*)(?P=q)""",
    re.I,
)


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


def script_tag(prefix: str) -> tuple[str, str]:
    body = INJECT_JS.replace("__PREFIX__", json.dumps(prefix))
    digest = base64.b64encode(hashlib.sha256(body.encode("utf-8")).digest()).decode("ascii")
    return "<script>" + body + "</script>", digest


def add_script_hash(csp: str, digest: str) -> str:
    token = f"'sha256-{digest}'"
    if token in csp:
        return csp
    parts = csp.split(";")
    found = False
    out: list[str] = []
    for part in parts:
        if part.strip().lower().startswith("script-src"):
            out.append(part.rstrip() + " " + token)
            found = True
        else:
            out.append(part)
    if not found:
        out.append(f" script-src 'self' {token}")
    return ";".join(out)


def rewrite_html(html: str, prefix: str) -> tuple[str, str]:
    if not prefix:
        return html, ""

    def repl(match: re.Match[str]) -> str:
        path = match.group("path")
        if path.startswith("//") or path == prefix or path.startswith(prefix + "/"):
            return match.group(0)
        quote = match.group("q")
        if "/_assets/" in path and "?" not in path:
            path = path + "?oc=207"
        return f"{match.group('attr')}={quote}{prefix}{path}{quote}"

    html = _ATTR_RE.sub(repl, html)
    tag, digest = script_tag(prefix)
    head = re.search(r"<head[^>]*>", html, flags=re.I)
    if head:
        at = head.end()
        html = html[:at] + tag + html[at:]
    else:
        html = tag + html
    return html, digest


def prefix_root_assets(text: str, prefix: str) -> str:
    """Prefix root-absolute /_assets/ paths. Leave ./_assets/ relative imports alone."""
    marker = prefix + "/_assets/"
    sentinel = "\u0000INGRESS_ASSET\u0000"
    text = text.replace(marker, sentinel)

    def repl(match: re.Match[str]) -> str:
        return match.group(1) + marker

    text = re.sub(r"""(^|["'`\s(=])/_assets/""", repl, text)
    return text.replace(sentinel, marker)


def rewrite_css(text: str, prefix: str) -> str:
    if not prefix:
        return text
    return prefix_root_assets(text, prefix)


def rewrite_js(text: str, prefix: str) -> str:
    if not prefix:
        return text
    text = text.replace("window.location.pathname", "globalThis.__ocPath()")
    text = text.replace("location.pathname", "globalThis.__ocPath()")
    text = text.replace(
        "get pathname(){return a()}",
        "get pathname(){return globalThis.__ocPath(a())}",
    )
    text = text.replace(
        "bc=(e,t)=>{let n=e.split(`/`).filter(Boolean);",
        "bc=(e,t)=>{e=globalThis.__ocPath(e);let n=e.split(`/`).filter(Boolean);",
    )
    # Vite's preload helper does `return "/" + file`, which throws away the
    # ingress directory and asks Home Assistant for /_assets/...
    text = text.replace(
        "function(e){return`/`+e}",
        "function(e){return`" + prefix + "/`+e}",
    )
    # Quoted module paths only. Solid calls a property named jsx; rewriting every
    # ".js" substring turns ".jsx" into ".js?oc=...x" and the script will not parse.
    # The entry tag and these imports must share one query, or the session page
    # loads a second copy of the app and MetaProvider is missing.
    def bust(match: re.Match[str]) -> str:
        return f"{match.group('q')}{match.group('path')}?oc=207{match.group('q')}"

    text = re.sub(
        r"""(?P<q>["'`])(?P<path>(?:\./|\.\./|/|_assets/)[A-Za-z0-9._/-]*\.js)(?P=q)""",
        bust,
        text,
    )
    text = prefix_root_assets(text, prefix)
    needle = "function hq(){return location.origin}"
    if needle in text:
        text = text.replace(
            needle,
            "function hq(){return location.origin+" + json.dumps(prefix) + "}",
            1,
        )
    return text


class ByteBuf:
    def __init__(self, reader: asyncio.StreamReader, pending: bytes = b""):
        self.reader = reader
        self.data = pending

    async def readuntil(self, sep: bytes = b"\r\n") -> bytes:
        while sep not in self.data:
            chunk = await self.reader.read(65536)
            if not chunk:
                raise ConnectionError("unexpected eof")
            self.data += chunk
            if len(self.data) > 8_000_000:
                raise RuntimeError("chunk header too large")
        index = self.data.find(sep)
        line = self.data[:index]
        self.data = self.data[index + len(sep) :]
        return line

    async def readexactly(self, size: int) -> bytes:
        while len(self.data) < size:
            chunk = await self.reader.read(max(65536, size - len(self.data)))
            if not chunk:
                raise ConnectionError("unexpected eof")
            self.data += chunk
        out = self.data[:size]
        self.data = self.data[size:]
        return out


def split_head(blob: bytes) -> tuple[bytes, bytes]:
    marker = b"\r\n\r\n"
    index = blob.find(marker)
    if index < 0:
        return blob, b""
    return blob[: index + 4], blob[index + 4 :]


async def read_head(reader: asyncio.StreamReader) -> tuple[bytes, bytes]:
    blob = b""
    while b"\r\n\r\n" not in blob:
        chunk = await reader.read(8192)
        if not chunk:
            break
        blob += chunk
        if len(blob) > 1_000_000:
            raise RuntimeError("headers too large")
    return split_head(blob)


def parse_headers(head: bytes) -> tuple[str, list[tuple[str, str]], dict[str, str]]:
    text = head.decode("iso-8859-1", errors="replace")
    lines = text.split("\r\n")
    start = lines[0]
    raw: list[tuple[str, str]] = []
    folded: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        name, value = line.split(":", 1)
        value = value.strip()
        raw.append((name, value))
        key = name.lower()
        folded[key] = value if key not in folded else folded[key] + ", " + value
    return start, raw, folded


def is_upgrade(headers: dict[str, str]) -> bool:
    return "upgrade" in headers.get("connection", "").lower() or bool(headers.get("upgrade"))


def decode_body(payload: bytes, headers: dict[str, str]) -> bytes:
    encoding = headers.get("content-encoding", "").lower()
    if "gzip" in encoding:
        return gzip.decompress(payload)
    if "deflate" in encoding:
        try:
            return zlib.decompress(payload)
        except zlib.error:
            return zlib.decompress(payload, -zlib.MAX_WBITS)
    return payload


def should_rewrite(path: str, content_type: str) -> str:
    lowered = content_type.lower()
    if "text/html" in lowered:
        return "html"
    if "javascript" in lowered or path.split("?", 1)[0].endswith(".js"):
        return "js"
    if "text/css" in lowered or path.split("?", 1)[0].endswith(".css"):
        return "css"
    return ""


async def read_chunked(reader: asyncio.StreamReader, pending: bytes) -> bytes:
    buf = ByteBuf(reader, pending)
    parts: list[bytes] = []
    while True:
        size_line = await buf.readuntil()
        size = int(size_line.split(b";", 1)[0].strip() or b"0", 16)
        if size == 0:
            while True:
                trailer = await buf.readuntil()
                if trailer == b"":
                    break
            return b"".join(parts)
        parts.append(await buf.readexactly(size))
        await buf.readexactly(2)


async def read_full_body(reader: asyncio.StreamReader, headers: dict[str, str], pending: bytes) -> bytes:
    if "chunked" in headers.get("transfer-encoding", "").lower():
        return await read_chunked(reader, pending)
    if "content-length" in headers:
        need = int(headers["content-length"])
        blob = pending
        while len(blob) < need:
            chunk = await reader.read(need - len(blob))
            if not chunk:
                break
            blob += chunk
        return blob[:need]
    blob = pending
    while True:
        chunk = await reader.read(65536)
        if not chunk:
            break
        blob += chunk
    return blob


def basic_authorization() -> str:
    password = os.environ.get("OPENCODE_PASSWORD", "")
    if not password:
        return ""
    user = os.environ.get("OPENCODE_SERVER_USERNAME", "opencode")
    token = base64.b64encode(f"{user}:{password}".encode()).decode("ascii")
    return "Basic " + token


def encode_request(head: bytes, body: bytes, upstream_host: str, upgrade: bool) -> bytes:
    start, raw, _headers = parse_headers(head)
    lines = [start]
    saw_authorization = False
    for name, value in raw:
        key = name.lower()
        if key == "host" or key == "accept-encoding":
            continue
        if not upgrade and (key in HOP_BY_HOP or key == "content-length"):
            continue
        if key == "authorization":
            saw_authorization = True
        lines.append(f"{name}: {value}")
    lines.append(f"Host: {upstream_host}")
    if not saw_authorization:
        authorization = basic_authorization()
        if authorization:
            lines.append(f"Authorization: {authorization}")
    if upgrade:
        lines.append("Connection: Upgrade")
    else:
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        if body:
            lines.append(f"Content-Length: {len(body)}")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1") + body


def encode_rewritten(
    start: str,
    raw_headers: list[tuple[str, str]],
    body: bytes,
    prefix: str,
    digest: str,
) -> bytes:
    lines = [start]
    for name, value in raw_headers:
        key = name.lower()
        if key in HOP_BY_HOP or key in ("content-length", "content-encoding", "cache-control", "expires"):
            continue
        if key == "location":
            value = rewrite_location(value, prefix)
        elif key == "set-cookie":
            value = rewrite_set_cookie(value, prefix)
        elif key == "content-security-policy" and digest:
            value = add_script_hash(value, digest)
        lines.append(f"{name}: {value}")
    lines.append("Cache-Control: no-cache")
    lines.append(f"Content-Length: {len(body)}")
    lines.append("Connection: close")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1") + body


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, first: bytes = b"") -> None:
    try:
        if first:
            writer.write(first)
            await writer.drain()
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


def request_path(start: str) -> str:
    parts = start.split(" ")
    return parts[1] if len(parts) > 1 else "/"


async def send_error(writer: asyncio.StreamWriter, message: str) -> None:
    body = message.encode("utf-8", errors="replace")
    writer.write(
        b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: "
        + str(len(body)).encode()
        + b"\r\nConnection: close\r\n\r\n"
        + body
    )
    await writer.drain()


def make_handler(upstream_host: str, upstream_port: int):
    async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
        path = "-"
        wrote = False
        try:
            head, pending = await read_head(client_reader)
            if not head:
                return
            start, _raw, headers = parse_headers(head)
            path = request_path(start)
            prefix = normalize_prefix(headers.get("x-ingress-path", ""))
            upgrade = is_upgrade(headers)
            body = b""
            if not upgrade and (
                "chunked" in headers.get("transfer-encoding", "").lower()
                or "content-length" in headers
            ):
                body = await read_full_body(client_reader, headers, pending)
                pending = b""

            upstream_reader, upstream_writer = await asyncio.open_connection(upstream_host, upstream_port)
            host_header = f"{upstream_host}:{upstream_port}"
            upstream_writer.write(encode_request(head, body, host_header, upgrade))
            await upstream_writer.drain()

            if upgrade:
                wrote = True
                print(f"[INFO] {path} websocket", flush=True)
                await asyncio.gather(
                    pipe(client_reader, upstream_writer, pending),
                    pipe(upstream_reader, client_writer),
                )
                return

            response_head, response_pending = await read_head(upstream_reader)
            if not response_head:
                await send_error(client_writer, "opencode proxy: empty response\n")
                wrote = True
                return
            status, response_raw, response_headers = parse_headers(response_head)
            content_type = response_headers.get("content-type", "")
            kind = should_rewrite(path, content_type)
            if kind:
                payload = await read_full_body(upstream_reader, response_headers, response_pending)
                payload = decode_body(payload, response_headers)
                text = payload.decode("utf-8", errors="replace")
                digest = ""
                if kind == "html":
                    text, digest = rewrite_html(text, prefix)
                elif kind == "css":
                    text = rewrite_css(text, prefix)
                else:
                    text = rewrite_js(text, prefix)
                rewritten = text.encode("utf-8")
                client_writer.write(encode_rewritten(status, response_raw, rewritten, prefix, digest))
                await client_writer.drain()
                wrote = True
                print(f"[INFO] {path} {status} rewritten {kind} {len(rewritten)}", flush=True)
                upstream_writer.close()
                return

            client_writer.write(response_head + response_pending)
            await client_writer.drain()
            wrote = True
            print(f"[INFO] {path} {status} stream", flush=True)
            await pipe(upstream_reader, client_writer)
            upstream_writer.close()
        except (asyncio.IncompleteReadError, ConnectionError, asyncio.TimeoutError) as exc:
            print(f"[WARN] {path} {type(exc).__name__}", flush=True)
            if not wrote:
                try:
                    await send_error(client_writer, "opencode proxy: connection closed\n")
                except Exception:
                    pass
        except Exception as exc:
            print(f"[ERROR] {path} {type(exc).__name__}: {exc}", flush=True)
            if not wrote:
                try:
                    await send_error(client_writer, f"opencode proxy: {type(exc).__name__}\n")
                except Exception:
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
    sample, digest = rewrite_html(
        '<head><script src="/_assets/app.js"></script></head>',
        "/api/hassio_ingress/abc",
    )
    assert "/api/hassio_ingress/abc/_assets/app.js" in sample, sample
    assert "globalThis.__ocPath" in sample
    assert digest
    csp = add_script_hash(
        "default-src 'self'; script-src 'self' 'sha256-AAAA'; style-src 'self'",
        digest,
    )
    assert f"'sha256-{digest}'" in csp
    js = rewrite_js(
        "function Zo(){let e=window.location.pathname+window.location.search}function hq(){return location.origin}"
        "function(e){return`/`+e}get pathname(){return a()}bc=(e,t)=>{let n=e.split(`/`).filter(Boolean);import(\"./_assets/current-abc.js\");import{n as e}from\"./index-C8GATERM.js\";e.toast.jsx;keep.json;//# sourceMappingURL=index-C8GATERM.js.map",
        "/api/hassio_ingress/abc",
    )
    assert "globalThis.__ocPath()" in js
    assert "window.location.pathname" not in js
    assert 'location.origin+"/api/hassio_ingress/abc"' in js
    assert "globalThis.__ocPath(a())" in js
    assert "globalThis.__ocPath(e)" in js
    assert "_assets/current-abc.js?oc=207" in js
    assert 'from"./index-C8GATERM.js?oc=207"' in js
    assert "e.toast.jsx" in js
    assert "keep.json" in js
    assert "?oc=207x" not in js
    assert "index-C8GATERM.js.map" in js
    assert "index-C8GATERM.js?oc=207.map" not in js
    assert "function(e){return`/api/hassio_ingress/abc/`+e}" in js
    os.environ["OPENCODE_PASSWORD"] = "secret"
    os.environ["OPENCODE_SERVER_USERNAME"] = "opencode"
    authed = encode_request(b"GET /api/info HTTP/1.1\r\nHost: ha.local\r\n\r\n", b"", "127.0.0.1:9", False)
    assert b"Authorization: Basic b3BlbmNvZGU6c2VjcmV0\r\n" in authed
    already = encode_request(
        b"GET /api/info HTTP/1.1\r\nHost: ha.local\r\nAuthorization: Basic dXNlcjpwYXNz\r\n\r\n",
        b"",
        "127.0.0.1:9",
        False,
    )
    assert already.count(b"Authorization:") == 1
    assert b"Basic dXNlcjpwYXNz" in already
    os.environ.pop("OPENCODE_PASSWORD", None)

    async def scenario() -> None:
        async def upstream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            head, pending = await read_head(reader)
            start, _raw, headers = parse_headers(head)
            if headers.get("content-length"):
                await read_full_body(reader, headers, pending)
            path = request_path(start)
            if path == "/app.js":
                body = b"function hq(){return location.origin} location.pathname"
                payload = (
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\nContent-Length: "
                    + str(len(body)).encode()
                    + b"\r\nContent-Encoding: identity\r\nConnection: close\r\n\r\n"
                    + body
                )
            else:
                body = b"<head><script type=\"module\" src=\"/_assets/app.js\"></script></head>"
                chunk = format(len(body), "x").encode() + b"\r\n" + body + b"\r\n0\r\n\r\n"
                payload = (
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n"
                    b"Content-Security-Policy: default-src 'self'; script-src 'self'\r\n"
                    b"Connection: close\r\n\r\n"
                    + chunk
                )
            writer.write(payload)
            await writer.drain()
            writer.close()

        upstream_server = await asyncio.start_server(upstream, "127.0.0.1", 0)
        upstream_port = upstream_server.sockets[0].getsockname()[1]
        proxy = await asyncio.start_server(make_handler("127.0.0.1", upstream_port), "127.0.0.1", 0)
        proxy_port = proxy.sockets[0].getsockname()[1]

        async def exchange(raw: bytes) -> bytes:
            reader, writer = await asyncio.open_connection("127.0.0.1", proxy_port)
            writer.write(raw)
            await writer.drain()
            data = await reader.read(-1)
            writer.close()
            return data

        page = await exchange(
            b"GET / HTTP/1.1\r\nHost: ha.local\r\nX-Ingress-Path: /api/hassio_ingress/abc\r\n"
            b"Accept-Encoding: gzip\r\nConnection: close\r\n\r\n"
        )
        text = page.decode("utf-8", errors="replace")
        assert "Transfer-Encoding" not in text.split("\r\n\r\n", 1)[0]
        assert "Content-Encoding" not in text.split("\r\n\r\n", 1)[0]
        assert "/api/hassio_ingress/abc/_assets/app.js" in text, text
        assert "sha256-" in text
        assert "globalThis.__ocPath" in text

        script = await exchange(
            b"GET /app.js HTTP/1.1\r\nHost: ha.local\r\nX-Ingress-Path: /api/hassio_ingress/abc\r\n"
            b"Connection: close\r\n\r\n"
        )
        script_text = script.decode("utf-8", errors="replace")
        assert "globalThis.__ocPath()" in script_text, script_text
        assert 'location.origin+"/api/hassio_ingress/abc"' in script_text

        proxy.close()
        upstream_server.close()
        await proxy.wait_closed()
        await upstream_server.wait_closed()

    asyncio.run(asyncio.wait_for(scenario(), 5))
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
