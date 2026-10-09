#!/bin/bash
# Compila las fuentes de la app (sin App.swift) junto con tests/main.swift y corre las pruebas.
set -e
cd "$(dirname "$0")/.."
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 $(ls *.swift | grep -v '^App.swift$') tests/main.swift -o /tmp/tp-optimizer-tests
/tmp/tp-optimizer-tests
