#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -parse-as-library -o "$WORK/workshop-tests" \
 "$ROOT/ZeuzDNC/Localization.swift" \
 "$ROOT/ZeuzDNC/Models/Machine.swift" \
 "$ROOT/ZeuzDNC/Models/ProgramEntry.swift" \
 "$ROOT/ZeuzDNC/Models/TransferState.swift" \
 "$ROOT/ZeuzDNC/Services/SMB/SMBPath.swift" \
 "$ROOT/ZeuzDNC/Services/Programs/ProgramClient.swift" \
 "$ROOT/ZeuzDNC/Services/Transport/ZeuzBridgeClient.swift" \
 "$ROOT/ZeuzDNC/Services/Agent/ZeuzAgentSettings.swift" \
 "$ROOT/ZeuzDNC/Services/Agent/ZeuzAgentProgramClient.swift" \
 "$ROOT/ZeuzDNC/Services/Stores/JSONFileStore.swift" \
 "$ROOT/ZeuzDNC/Services/Stores/Keychain.swift" \
 "$ROOT/Tools/WorkshopClientTests.swift"
"$WORK/workshop-tests"
