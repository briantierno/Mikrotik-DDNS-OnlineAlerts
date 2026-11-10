#!/usr/bin/env python3
"""Impresora ESC/POS falsa: escucha RAW en :9100 y muestra los tickets en http://IP:8080
Solo stdlib. Uso: python3 escpos_viewer.py [--ip 0.0.0.0] [--port 9100] [--web 8080]
"""
import argparse, html, socket, socketserver, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TICKETS = []          # [(hora, html)]
LOCK = threading.Lock()
CODEPAGES = {0: "cp437", 2: "cp850", 16: "cp1252", 19: "cp858"}


def render(data: bytes):
    """Convierte bytes ESC/POS en una lista de tickets HTML (se separan por corte)."""
    tickets, lines, cur = [], [], []
    st = dict(bold=False, ul=False, inv=False, big=False, align="left", cp="cp850")

    def flush_text(buf):
        if buf:
            t = html.escape(bytes(buf).decode(st["cp"], "replace"))
            css = []
            if st["bold"]: css.append("font-weight:bold")
            if st["ul"]: css.append("text-decoration:underline")
            if st["inv"]: css.append("background:#000;color:#fff")
            if st["big"]: css.append("font-size:1.8em")
            cur.append(f'<span style="{";".join(css)}">{t}</span>' if css else t)
            buf.clear()

    def newline():
        lines.append(f'<div style="text-align:{st["align"]}">{"".join(cur) or "&nbsp;"}</div>')
        cur.clear()

    def cut():
        if lines or cur:
            if cur: newline()
            tickets.append("".join(lines)); lines.clear()

    buf, i, n = bytearray(), 0, len(data)
    arg = lambda k: data[i + k] if i + k < n else 0
    while i < n:
        b = data[i]
        if b == 0x0A:
            flush_text(buf); newline(); i += 1
        elif b == 0x1B:  # ESC
            flush_text(buf); c = arg(1)
            if c == 0x40: st.update(bold=False, ul=False, inv=False, big=False, align="left"); i += 2
            elif c == 0x21: m = arg(2); st["bold"] = bool(m & 8); st["big"] = bool(m & 0x30); st["ul"] = bool(m & 0x80); i += 3
            elif c == 0x45: st["bold"] = bool(arg(2) & 1); i += 3
            elif c == 0x2D: st["ul"] = bool(arg(2) & 3); i += 3
            elif c == 0x61: st["align"] = ["left", "center", "right"][arg(2) % 48 % 3]; i += 3
            elif c == 0x64: [newline() for _ in range(min(arg(2), 20))]; i += 3
            elif c == 0x74: st["cp"] = CODEPAGES.get(arg(2), "cp850"); i += 3
            elif c == 0x70: i += 5                                   # cajón
            elif c == 0x2A: w = arg(3) + arg(4) * 256; i += 5 + w * (3 if arg(2) >= 32 else 1); cur.append("[imagen]")
            elif c in (0x32, 0x3C): i += 2
            else: i += 3                                             # resto: ESC x n
        elif b == 0x1D:  # GS
            flush_text(buf); c = arg(1)
            if c == 0x21: st["big"] = bool(arg(2)); i += 3
            elif c == 0x42: st["inv"] = bool(arg(2) & 1); i += 3
            elif c == 0x56: i += 4 if arg(2) in (65, 66, 97, 98) else 3; cut()
            elif c == 0x76: w = arg(4) + arg(5) * 256; h = arg(6) + arg(7) * 256; i += 8 + w * h; cur.append("[imagen]"); newline()
            elif c == 0x28:  # GS ( x pL pH ...
                L = arg(3) + arg(4) * 256; blk = data[i + 5:i + 5 + L]
                if arg(2) == 0x6B and len(blk) > 3 and blk[1] == 80:
                    cur.append(f"[QR: {html.escape(blk[3:].decode('latin1'))}]"); newline()
                i += 5 + L
            elif c == 0x6B:  # código de barras
                m = arg(2)
                if m <= 6: j = data.find(b"\0", i + 3); j = n if j < 0 else j; d = data[i + 3:j]; i = j + 1
                else: L = arg(3); d = data[i + 4:i + 4 + L]; i += 4 + L
                cur.append(f"[barras: {html.escape(d.decode('latin1'))}]"); newline()
            elif c in (0x4C, 0x57): i += 4
            else: i += 3
        elif b == 0x1C: i += 4 if arg(1) == 0x70 else 2          # FS
        elif b == 0x10: i += 3 if arg(1) == 0x04 else 5              # DLE
        elif b in (0x0D, 0x00, 0x0C): i += 1
        else:
            buf.append(b); i += 1
    flush_text(buf); cut()
    return tickets


class RawHandler(socketserver.BaseRequestHandler):
    def handle(self):
        s, chunks = self.request, []
        s.settimeout(2)  # 2 s sin datos = fin del trabajo
        try:
            while True:
                d = s.recv(65536)
                if not d: break
                chunks.append(d)
                if b"\x10\x04" in d: s.sendall(b"\x12")   # consulta de estado -> "online"
        except (socket.timeout, OSError):
            pass
        data = b"".join(chunks)
        if not data: return
        t = time.strftime("%H:%M:%S")
        with LOCK:
            for tk in render(data):
                TICKETS.insert(0, (f"{t} · {self.client_address[0]} · {len(data)} bytes", tk))
            del TICKETS[100:]
        print(f"[{t}] {self.client_address[0]}: {len(data)} bytes")


PAGE = """<!doctype html><meta charset=utf-8><meta http-equiv=refresh content=2><title>ESC/POS</title>
<style>body{{background:#ddd;font-family:sans-serif;margin:0;padding:16px}}
.t{{background:#fff;width:48ch;margin:0 auto 24px;padding:12px;font:13px/1.3 monospace;white-space:pre-wrap;box-shadow:0 2px 6px #0004}}
.h{{width:48ch;margin:0 auto;font-size:12px;color:#555}}a{{float:right}}</style>
<div class=h><a href=/clear>limpiar</a>{n} ticket(s)</div><br>{body}"""


class Web(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/clear":
            with LOCK: TICKETS.clear()
            self.send_response(303); self.send_header("Location", "/"); self.end_headers(); return
        with LOCK:
            body = "".join(f'<div class=h>{h}</div><div class=t>{t}</div>' for h, t in TICKETS)
            out = PAGE.format(n=len(TICKETS), body=body).encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a): pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="0.0.0.0"); ap.add_argument("--port", type=int, default=9100)
    ap.add_argument("--web", type=int, default=8080)
    a = ap.parse_args()
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    raw = socketserver.ThreadingTCPServer((a.ip, a.port), RawHandler)
    threading.Thread(target=raw.serve_forever, daemon=True).start()
    print(f"Impresora RAW en {a.ip}:{a.port}  ->  tickets en http://{a.ip if a.ip != '0.0.0.0' else 'localhost'}:{a.web}")
    ThreadingHTTPServer((a.ip, a.web), Web).serve_forever()
