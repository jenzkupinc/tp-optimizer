#!/bin/bash
# Compila las fuentes de la app (sin App.swift) con -D TESTING junto con tests/*.swift y corre las pruebas
# en una carpeta de usuario falsa (TP_HOME), sin tocar tus archivos ni tu Mac.
set -e
cd "$(dirname "$0")/.."
export TP_HOME=$(mktemp -d)
trap 'rm -rf "$TP_HOME"' EXIT
xcrun swiftc -O -swift-version 5 -D TESTING -target arm64-apple-macosx26.0 $(ls *.swift | grep -v '^App.swift$') tests/*.swift -o /tmp/tp-optimizer-tests
/tmp/tp-optimizer-tests
