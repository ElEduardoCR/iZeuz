#!/usr/bin/env python3
"""Puente serial falso: acepta una conexion TCP, guarda lo que recibe y puede
simular el control de flujo XON/XOFF de una CNC real."""
import socket
import sys
import threading
import time

PORT = int(sys.argv[1])
OUT = sys.argv[2]
MODE = sys.argv[3] if len(sys.argv) > 3 else "plain"

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", PORT))
server.listen(1)
print(f"escuchando en {PORT} modo={MODE}", flush=True)

conn, _ = server.accept()
received = bytearray()


def flow_control():
    """Manda XOFF apenas se conecta y XON casi un segundo despues, como una
    maquina cuyo buffer se llena enseguida. Sobre TCP en loopback los bloques
    salen en milisegundos, asi que el XOFF tiene que llegar de inmediato para
    alcanzar a frenar el envio."""
    time.sleep(0.02)
    conn.sendall(b"\x13")      # XOFF
    time.sleep(0.9)
    conn.sendall(b"\x11")      # XON


if MODE == "xonxoff":
    threading.Thread(target=flow_control, daemon=True).start()

conn.settimeout(6.0)
try:
    while True:
        chunk = conn.recv(4096)
        if not chunk:
            break
        received.extend(chunk)
except socket.timeout:
    pass

with open(OUT, "wb") as f:
    f.write(bytes(received))
print(f"recibidos {len(received)} bytes", flush=True)
conn.close()
server.close()
