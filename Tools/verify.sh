#!/bin/bash
# Ejercita el nucleo de envio contra un puente serial falso.
#
# Compila los MISMOS archivos que usa la app (sin SwiftUI ni SMB) y verifica
# que los bytes que salen por el cable sean exactamente los correctos, que el
# control de flujo XON/XOFF frene el envio de verdad, y que un puente apagado
# de un error entendible en vez de colgarse.
#
#   ./Tools/verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; kill $(jobs -p) 2>/dev/null || true' EXIT

PORT_SIMPLE=9971
PORT_FLOW=9972

echo "==> Compilando el banco de pruebas"
cp "$ROOT/Tools/TransportTests.swift" "$WORK/main.swift"
swiftc -swift-version 6 -O -o "$WORK/harness" \
  "$ROOT/ZeuzDNC/Models/Machine.swift" \
  "$ROOT/ZeuzDNC/Models/SerialEndpoint.swift" \
  "$ROOT/ZeuzDNC/Models/ProgramEntry.swift" \
  "$ROOT/ZeuzDNC/Models/TransferState.swift" \
  "$ROOT/ZeuzDNC/Services/SMB/SMBPath.swift" \
  "$ROOT/ZeuzDNC/Services/Transport/SerialTransport.swift" \
  "$ROOT/ZeuzDNC/Services/Transport/NetworkBridgeTransport.swift" \
  "$ROOT/ZeuzDNC/Services/Transport/MockTransport.swift" \
  "$ROOT/ZeuzDNC/Services/Transport/MFiSerialTransport.swift" \
  "$ROOT/ZeuzDNC/Services/Transport/TransportFactory.swift" \
  "$ROOT/ZeuzDNC/Services/GCodeSender.swift" \
  "$WORK/main.swift"

echo "==> Levantando los puentes falsos"
python3 "$ROOT/Tools/fake_bridge.py" "$PORT_SIMPLE" "$WORK/got_simple.bin" plain > "$WORK/b1.log" 2>&1 &
sleep 0.4
python3 "$ROOT/Tools/fake_bridge.py" "$PORT_FLOW" "$WORK/got_flow.bin" xonxoff > "$WORK/b2.log" 2>&1 &
sleep 0.6

echo "==> Ejecutando las pruebas"
"$WORK/harness" "$PORT_SIMPLE" "$PORT_FLOW" "$WORK/got_simple.bin"
STATUS=$?

echo ""
echo "==> Verificando los bytes que llegaron al puente"
sleep 7
python3 - "$WORK" <<'PYEOF'
import sys, os
work = sys.argv[1]
ok = True

expected = b"O0001\r\nG21 G90\r\nG00 X10. Y10.\r\nG01 Z-5. F100\r\nM30\r\n"
got = open(os.path.join(work, "got_simple.bin"), "rb").read()
if got == expected:
    print("  OK   los bytes en el cable son exactamente los esperados")
else:
    ok = False
    print(f"  FALLA bytes distintos:\n    recibido {got!r}\n    esperado {expected!r}")

flow = open(os.path.join(work, "got_flow.bin"), "rb").read()
lines = [l for l in flow.split(b"\r\n") if l]
if len(lines) == 400:
    print("  OK   las 400 lineas sobreviven intactas a la pausa por XOFF")
else:
    ok = False
    print(f"  FALLA llegaron {len(lines)} lineas de 400")

sys.exit(0 if ok else 1)
PYEOF

echo ""
echo "Verificacion completa."
