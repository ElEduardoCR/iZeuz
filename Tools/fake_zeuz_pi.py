#!/usr/bin/env python3
"""Raspberry Pi FALSA con ZeuzDNC, para probar el modo "Puente ZeuzDNC" del
iPhone sin la Pi real y, sobre todo, sin arriesgar el torno.

Imita las rutas HTTP que la app usa (las mismas del app.py real) y simula una
transferencia que avanza de 0% a 100% en unos segundos. No abre ningun puerto
serial: solo reproduce el contrato para que puedas ver la barra de progreso,
la finalizacion y la cancelacion desde el iPhone.

Uso:
    python3 Tools/fake_zeuz_pi.py [puerto]     # por defecto 5000

Luego, en la app: Ajustes -> Puertos -> Puerto nuevo -> "Puente ZeuzDNC",
IP = la de esta Mac, Puerto = el que elijas aqui. Elige una maquina llamada
"Fanuc" o "Fadal" (existen en este servidor falso), abre un programa y ENVIAR.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5000

# Maquinas que "tiene" esta Pi falsa. El iPhone empareja por NOMBRE, asi que
# para probar, la maquina elegida en el iPhone debe llamarse igual que una de
# estas (Fanuc/Fadal son las de fabrica de la app).
MACHINES = [
    {"id": "fanuc", "name": "Fanuc", "baudrate": 4800, "bytesize": 7,
     "parity": "E", "stopbits": 2, "flow_control": "xonxoff",
     "line_terminator": "CR", "dtr": False, "rts": False, "dripfeed": False},
    {"id": "fadal", "name": "Fadal", "baudrate": 9600, "bytesize": 8,
     "parity": "N", "stopbits": 1, "flow_control": "xonxoff",
     "line_terminator": "CRLF", "dtr": False, "rts": False, "dripfeed": False},
]

_lock = threading.Lock()
_transfer = {
    "status": "idle", "filename": None, "machine": None,
    "bytes_sent": 0, "total_bytes": 0, "percent": 0, "message": "",
}
_active_machine_id = None
_cancel = threading.Event()
# Contenido empujado por /api/file/save, por ruta. La Pi real lee el archivo
# del disco al enviar; aqui lo guardamos en memoria para calcular el total
# igual que ella (con el contenido, no con el cuerpo del /api/send).
_saved = {}


def _set(**kw):
    with _lock:
        _transfer.update(kw)


def _snapshot():
    with _lock:
        return dict(_transfer)


def _run_fake_transfer(filename, content):
    """Sube de 0 a 100% simulando ~2.5 s de envio, respetando la cancelacion."""
    _cancel.clear()
    total = max(len(content.encode("latin-1", "replace")), 1)
    _set(status="sending", filename=filename, bytes_sent=0,
         total_bytes=total, percent=0, message="")
    steps = 25
    for i in range(1, steps + 1):
        if _cancel.is_set():
            _set(status="cancelled", message="Envio cancelado")
            return
        time.sleep(0.1)
        sent = int(total * i / steps)
        _set(bytes_sent=sent, percent=int(sent * 100 / total))
    _set(message="Finalizando envio...")
    time.sleep(0.3)
    _set(status="success", bytes_sent=total, percent=100,
         message="Transferencia completada")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("  " + (fmt % args), flush=True)

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        if self.path == "/api/machines":
            return self._json(MACHINES)
        if self.path == "/api/transfer/status":
            return self._json(_snapshot())
        return self._json({"ok": False, "error": "ruta no encontrada"}, 404)

    def do_POST(self):
        global _active_machine_id
        data = self._read_json()

        if self.path == "/api/device/select":
            return self._json({"ok": True})

        if self.path == "/api/machine/select":
            mid = data.get("id")
            if not any(m["id"] == mid for m in MACHINES):
                return self._json({"ok": False, "error": "Maquina invalida"}, 400)
            _active_machine_id = mid
            return self._json({"ok": True})

        if self.path == "/api/file/save":
            # La Pi real la escribe en su carpeta; aqui la recordamos para
            # calcular el total al enviar, como haria ella leyendo el archivo.
            _saved[data.get("path", "")] = data.get("content", "")
            return self._json({"ok": True})

        if self.path == "/api/send":
            if _active_machine_id is None:
                return self._json(
                    {"ok": False, "error": "Selecciona una maquina antes de enviar"}, 409)
            if _snapshot()["status"] == "sending":
                return self._json(
                    {"ok": False, "error": "Ya hay una transferencia en curso"}, 409)
            path = data.get("path") or "programa"
            filename = path.split("/")[-1]
            # El iPhone ya no empuja el contenido (manda el archivo que vive en
            # la Pi). Si nadie lo guardo aqui, simulamos uno de ~2 KB para que la
            # barra de progreso tenga algo que recorrer en la prueba.
            content = _saved.get(path) or ("(PROGRAMA DE PRUEBA)\n" + "N10 G01 X1. Y1.\n" * 120)
            _set(status="idle", machine=_active_machine_id)
            threading.Thread(
                target=_run_fake_transfer,
                args=(filename, content),
                daemon=True,
            ).start()
            return self._json({"ok": True})

        if self.path == "/api/send/cancel":
            _cancel.set()
            return self._json({"ok": True})

        return self._json({"ok": False, "error": "ruta no encontrada"}, 404)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Pi falsa ZeuzDNC escuchando en http://0.0.0.0:{PORT}", flush=True)
    print("Maquinas: " + ", ".join(m["name"] for m in MACHINES), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nadios", flush=True)
