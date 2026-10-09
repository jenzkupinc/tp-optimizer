#!/bin/bash
# Pruebas del ayudante con privilegios. Compila helper/tp-root.swift con -D TESTING, donde cada herramienta del
# sistema se reemplaza por un registro de llamadas, y comprueba qué acepta, qué rechaza y qué ejecutaría.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
BIN="$T/tp-root-test"
xcrun swiftc -O -swift-version 5 -D TESTING -target arm64-apple-macosx26.0 helper/tp-root.swift -o "$BIN" 2>&1 | grep -E "error" && exit 2
VERSION=$(sed -n 's/^let helperVersion = "\(.*\)"/\1/p' helper/tp-root.swift)
UIDN=$(id -u)
FAILTOOL=""; NV=""; FLOWS=""; SERVICES=$'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\nEthernet'
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1  [$2]"; }
run() { env ${FAILTOOL:+TP_T_FAIL=$FAILTOOL} TP_T_QOSFILE="$T/qos.rules" TP_T_APPS="$T/apps" TP_T_HELPERDIR="$T/helperdir" TP_T_NEWVERSION="$NV" TP_T_DAEMONS="$T/daemons" TP_T_AGENTS="$T/agents" TP_T_HOSTS="$T/hosts" TP_T_AUDIT="$T/audit" TP_T_CALLS="$T/calls" TP_T_HOME="$T/home" TP_T_LISTAPPS="/Applications/Listada.app" TP_T_FLOWS="$FLOWS" TP_T_SERVICES="$SERVICES" SUDO_UID=$UIDN "$BIN" "$@"; }
calls() { [ -f "$T/calls" ] && cat "$T/calls" || true; }
reset() { rm -rf "$T/calls" "$T/audit" "$T/qos.rules" "$T/daemons" "$T/agents" "$T/home" "$T/apps"; mkdir -p "$T/apps" "$T/helperdir" "$T/daemons" "$T/agents" "$T/home/.Trash"; printf '127.0.0.1 localhost\n' > "$T/hosts"; FAILTOOL=""; NV=""; FLOWS=""; }
good() { local what=$1; shift; reset; run "$@" >/dev/null 2>&1; local c=$?; [ $c -eq 0 ] && ok "$what" || bad "$what" "salida $c"; }
nope() { local what=$1; shift; reset; run "$@" >/dev/null 2>&1; local c=$?; [ $c -eq 65 ] && [ -z "$(calls)" ] && ok "$what" || bad "$what" "salida $c, llamadas: $(calls | tr '\n' '|')"; }
nopeK() { local what=$1; shift; rm -f "$T/calls"; run "$@" >/dev/null 2>&1; local c=$?; [ $c -eq 65 ] && [ -z "$(calls)" ] && ok "$what" || bad "$what" "salida $c, llamadas: $(calls | tr '\n' '|')"; }
has() { calls | grep -qF -- "$1"; }

reset
[ "$(run version)" = "$VERSION" ] && ok "version coincide con el código fuente ($VERSION)" || bad "version" "$(run version)"
run >/dev/null 2>&1; [ $? -eq 64 ] && ok "sin argumentos sale con 64" || bad "sin argumentos" "$?"
nope "una operación desconocida se rechaza sin ejecutar nada" borrar-todo

good "deep ejecuta purge, limpia DNS y reinicia mDNSResponder" deep
[ "$(calls | sed -n 1p)" = "/usr/sbin/purge" ] && has "dscacheutil -flushcache" && has "killall -HUP mDNSResponder" && ok "deep llama a las tres herramientas" || bad "deep llamadas" "$(calls | tr '\n' '|')"
nope "deep con argumentos de más se rechaza" deep ahora
reset; FAILTOOL=purge; run deep >/dev/null 2>&1; [ $? -eq 65 ] && ok "si purge falla, deep avisa del fallo" || bad "deep con purge roto" "$?"

good "schedule acepta un encendido de lunes a viernes" schedule wake MTWRF 07:00:00
has "pmset repeat cancel" && has "pmset repeat wake MTWRF 07:00:00" && ok "schedule cancela lo anterior y fija el nuevo horario" || bad "schedule llamadas" "$(calls | tr '\n' '|')"
good "schedule sin horarios solo cancela" schedule
nope "schedule rechaza un tipo inventado" schedule explotar MTWRF 07:00:00
nope "schedule rechaza días fuera de lista" schedule wake XYZ 07:00:00
nope "schedule rechaza una hora sin ceros" schedule wake MTWRF 7:00:00
nope "schedule rechaza una hora imposible" schedule wake MTWRF 25:00:00
nope "schedule rechaza más de dos horarios" schedule wake M 07:00:00 sleep M 22:00:00 restart M 03:00:00

good "hosts bloquea dos dominios válidos" hosts malo.com otro.example.org
grep -q "0.0.0.0 malo.com" "$T/hosts" && grep -q "0.0.0.0 otro.example.org" "$T/hosts" && grep -q "127.0.0.1 localhost" "$T/hosts" && ok "hosts escribe el bloque y conserva lo que ya había" || bad "hosts contenido" "$(cat "$T/hosts")"
has "dscacheutil -flushcache" && ok "hosts limpia la caché DNS al terminar" || bad "hosts sin flush" ""
run hosts malo.com >/dev/null 2>&1; run hosts malo.com >/dev/null 2>&1
[ "$(grep -c 'TP Optimizer: inicio' "$T/hosts")" = "1" ] && ok "repetir hosts no duplica el bloque" || bad "hosts duplicado" "$(grep -c 'inicio' "$T/hosts")"
run hosts >/dev/null 2>&1
! grep -q "TP Optimizer" "$T/hosts" && grep -q "localhost" "$T/hosts" && ok "hosts sin dominios quita el bloque y deja el resto" || bad "hosts vacío" "$(cat "$T/hosts")"
before=$(cat "$T/hosts")
nopeK "hosts rechaza un dominio con espacio" hosts "a b.com"
nopeK "hosts rechaza una inyección con punto y coma" hosts "x.com;rm"
nopeK "hosts rechaza un nombre sin punto" hosts localhost
nopeK "hosts rechaza una IP como dominio" hosts 1.2.3.4
[ "$(cat "$T/hosts")" = "$before" ] && ok "los rechazos no tocaron el archivo hosts" || bad "hosts alterado" ""

reset; mkdir -p "$T/Fake.app"
run fw stealth on >/dev/null 2>&1; has "--setstealthmode on" && ok "fw stealth on llama a socketfilterfw" || bad "fw stealth" "$(calls)"
nope "fw stealth con un valor raro" fw stealth quizas
reset; run fw block "$T/Fake.app" >/dev/null 2>&1; c=$?; has "--blockapp $T/Fake.app" && [ $c -eq 0 ] && ok "fw block acepta una .app que existe" || bad "fw block" "salida $c $(calls)"
reset; run fw add "$T/Fake.app" >/dev/null 2>&1; has "--add $T/Fake.app" && has "--blockapp $T/Fake.app" && ok "fw add la agrega y la bloquea" || bad "fw add" "$(calls)"
nope "fw rechaza una ruta relativa" fw block Fake.app
nope "fw rechaza subir de carpeta con .." fw block "$T/../etc/Fake.app"
nope "fw rechaza la raíz «/»" fw block /
nope "fw rechaza una carpeta que no es app" fw block /Applications
nope "fw rechaza un trozo de una ruta listada" fw unblock /Applications/Lis
reset; run fw unblock /Applications/Listada.app >/dev/null 2>&1; c=$?; has "--unblockapp /Applications/Listada.app" && [ $c -eq 0 ] && ok "fw unblock acepta la ruta exacta que el firewall lista" || bad "fw unblock exacta" "salida $c $(calls)"
nope "fw add exige que el archivo exista en disco" fw add /Applications/Inventada.app
nope "fw con una operación desconocida" fw borrar x

good "flows acepta una MAC y 5 segundos por defecto" flows aa:bb:cc:dd:ee:ff
has "tcpdump -i bridge100" && has "ether host aa:bb:cc:dd:ee:ff" && ok "flows captura solo en bridge100 y filtra por esa MAC" || bad "flows llamadas" "$(calls)"
reset; run flows AA:BB:CC:DD:EE:FF >/dev/null 2>&1; has "ether host aa:bb:cc:dd:ee:ff" && ok "flows pasa la MAC a minúsculas" || bad "flows mayúsculas" "$(calls)"
good "flows acepta 10 y 15 segundos" flows aa:bb:cc:dd:ee:ff 10
nope "flows rechaza 7 segundos" flows aa:bb:cc:dd:ee:ff 7
nope "flows rechaza una MAC mal formada" flows aa:bb:cc:dd:ee
nope "flows rechaza inyección en la MAC" flows "aa:bb:cc:dd:ee:ff;ls"
reset; FLOWS="udp 1.2.3.4.5555 > 5.6.7.8.20000: UDP"; out=$(run flows aa:bb:cc:dd:ee:ff); echo "$out" | grep -q "20000" && ok "flows devuelve lo capturado" || bad "flows salida" "$out"

good "dns set acepta un servicio real y dos servidores" dns set Wi-Fi 9.9.9.9 149.112.112.112
has "-setdnsservers Wi-Fi 9.9.9.9 149.112.112.112" && has "dscacheutil -flushcache" && ok "dns set cambia los servidores y limpia la caché" || bad "dns set llamadas" "$(calls)"
good "dns set acepta IPv6" dns set Wi-Fi 2606:4700:4700::1111
good "dns reset deja el servicio en automático" dns reset Wi-Fi
has "-setdnsservers Wi-Fi Empty" && ok "dns reset usa «Empty»" || bad "dns reset" "$(calls)"
good "dns acepta un servicio deshabilitado (con asterisco)" dns set "Thunderbolt Bridge" 1.1.1.1
nope "dns rechaza un servicio que no existe" dns set Inventado 1.1.1.1
nope "dns rechaza una dirección incompleta" dns set Wi-Fi 9.9.9
nope "dns rechaza texto en vez de dirección" dns set Wi-Fi google.com
nope "dns set exige al menos un servidor" dns set Wi-Fi
nope "dns reset no admite servidores" dns reset Wi-Fi 1.1.1.1
nope "dns rechaza nueve servidores" dns set Wi-Fi 1.1.1.1 1.1.1.2 1.1.1.3 1.1.1.4 1.1.1.5 1.1.1.6 1.1.1.7 1.1.1.8 1.1.1.9

reset; mkdir -p "$T/nuevo/Contents/Resources"; printf 'binario nuevo' > "$T/nuevo/Contents/Resources/tp-root"; printf 'viejo' > "$T/helperdir/app.tpoptimizer.root"
NV=$((VERSION+1)); run update "$T/nuevo/Contents/Resources/tp-root" >/dev/null 2>&1; c=$?
[ $c -eq 0 ] && [ "$(cat "$T/helperdir/app.tpoptimizer.root")" = "binario nuevo" ] && ok "update instala un ayudante con versión mayor" || bad "update válido" "salida $c"
has "codesign --verify" && ok "update verifica la firma antes de instalar" || bad "update sin firma" "$(calls)"
[ ! -e "$T/helperdir/app.tpoptimizer.root.new" ] && ok "update no deja el archivo temporal" || bad "update temporal" ""
for v in "$VERSION" "$((VERSION-1))" 0 abc ""; do reset; printf 'viejo' > "$T/helperdir/app.tpoptimizer.root"; NV="$v"; run update "$T/nuevo/Contents/Resources/tp-root" >/dev/null 2>&1; c=$?
  [ $c -eq 65 ] && [ "$(cat "$T/helperdir/app.tpoptimizer.root")" = "viejo" ] && ok "update rechaza la versión «$v» y deja el ayudante intacto" || bad "update versión $v" "salida $c"; done
reset; printf 'viejo' > "$T/helperdir/app.tpoptimizer.root"; NV=$((VERSION+1)); FAILTOOL=codesign; run update "$T/nuevo/Contents/Resources/tp-root" >/dev/null 2>&1; c=$?
[ $c -eq 65 ] && [ "$(cat "$T/helperdir/app.tpoptimizer.root")" = "viejo" ] && ok "si la firma no coincide, update no instala nada" || bad "update firma falsa" "salida $c"
reset; NV=$((VERSION+1))
nope "update rechaza una ruta relativa" update Contents/Resources/tp-root
nope "update rechaza una ruta que no termina en tp-root" update "$T/nuevo/Contents/Resources/otro"
nope "update rechaza subir de carpeta con .." update "$T/nuevo/Contents/../Contents/Resources/tp-root"
nope "update rechaza un archivo que no existe" update "$T/vacio/Contents/Resources/tp-root"
mkdir -p "$T/enlace/Contents/Resources"; ln -sf "$T/nuevo/Contents/Resources/tp-root" "$T/enlace/Contents/Resources/tp-root"
nope "update rechaza un enlace simbólico" update "$T/enlace/Contents/Resources/tp-root"

good "netinfo recoge el estado de pf y de dnctl" netinfo
has "pfctl -s info" && has "dnctl pipe show" && ok "netinfo consulta pf y las tuberías" || bad "netinfo" "$(calls | head -3)"
nope "netinfo no admite argumentos" netinfo x
reset; out=$(run netinfo); [ -z "$(echo "$out" | grep -E 'set |delete|-F|-f ')" ] && ok "netinfo solo lee, no cambia nada" || bad "netinfo escribe" ""

STATE=$'all udp 45.32.173.233:51820 <- 192.168.2.3:62568       MULTIPLE:SINGLE\nall udp 8.8.8.8:53 <- 192.168.2.3:5353       MULTIPLE:SINGLE\nall udp 2001:db8::1[51820] <- fdc3:d313:7b88:38d:44e:e725:485b:c1f6[55555]       MULTIPLE:SINGLE'
reset; FLOWS="$STATE"; out=$(run reroll 192.168.2.3 fdc3:d313:7b88:38d:44e:e725:485b:c1f6); c=$?
echo "$out" | grep -q "pares 2 cortados 2" && [ $c -eq 0 ] && ok "reroll corta solo los dos estados del túnel (IPv4 e IPv6)" || bad "reroll dos pares" "$out salida $c"
has "pfctl -k 192.168.2.3 -k 45.32.173.233" && has "pfctl -k fdc3:d313:7b88:38d:44e:e725:485b:c1f6 -k 2001:db8::1" && ok "reroll usa las parejas exactas" || bad "reroll llamadas" "$(calls | grep -- '-k')"
! calls | grep -q "8.8.8.8" && ok "reroll no toca el DNS ni otro tráfico" || bad "reroll tocó otro tráfico" ""
reset; FLOWS="$STATE"; out=$(run reroll 192.168.2.99); echo "$out" | grep -q "pares 0 cortados 0" && ok "si el cliente no tiene túnel, reroll no corta nada" || bad "reroll sin pares" "$out"
nope "reroll rechaza una IP pública como cliente" reroll 8.8.8.8
nope "reroll rechaza clientes repetidos" reroll 192.168.2.3 192.168.2.3
nope "reroll rechaza más de cuatro clientes" reroll 192.168.2.1 192.168.2.2 192.168.2.3 192.168.2.4 192.168.2.5
nope "reroll exige al menos un cliente" reroll
reset; FLOWS="$STATE"; FAILTOOL=pfctl; run reroll 192.168.2.3 >/dev/null 2>&1; [ $? -eq 65 ] && ok "si pf se niega a cortar, reroll lo dice" || bad "reroll con pf roto" "$?"

good "qos apply limita a dos clientes a 5 Mbit/s" qos apply 5 192.168.2.4 fdc3:d313:7b88:38d:1cea:1a6b:37b6:3c93
has "dnctl pipe 61 config bw 5Mbit/s queue 50" && has "dnctl pipe 62 config bw 5Mbit/s queue 50" && ok "qos apply configura las dos tuberías" || bad "qos tuberías" "$(calls | head -4)"
has "dummynet in on bridge100 inet from 192.168.2.4 to any pipe 61" && has "dummynet out on bridge100 inet6 from any to fdc3:d313:7b88:38d:1cea:1a6b:37b6:3c93 pipe 62" && ok "qos apply escribe reglas por familia y sentido" || bad "qos reglas" "$(calls | tail -6)"
[ ! -e "$T/qos.rules" ] && ok "qos apply borra el archivo de reglas al terminar" || bad "qos archivo" ""
for bad_args in "apply 0 192.168.2.4" "apply 1001 192.168.2.4" "apply abc 192.168.2.4" "apply 5 8.8.8.8" "apply 5 192.168.2.4 192.168.2.4" "apply 5" "apply 5 192.168.2.4;ls"; do nope "qos rechaza «$bad_args»" qos $bad_args; done
nope "qos rechaza 17 direcciones" qos apply 5 10.0.0.1 10.0.0.2 10.0.0.3 10.0.0.4 10.0.0.5 10.0.0.6 10.0.0.7 10.0.0.8 10.0.0.9 10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.13 10.0.0.14 10.0.0.15 10.0.0.16 10.0.0.17
reset; FAILTOOL=dnctl; run qos apply 5 192.168.2.4 >/dev/null 2>&1; c=$?
[ $c -eq 65 ] && ! has "-a com.apple/260.TPOptimizer -f" && ok "si una tubería falla, no se carga ninguna regla" || bad "qos con dnctl roto" "salida $c"
reset; run qos clear >/dev/null 2>&1; c=$?
[ $c -eq 0 ] && [ "$(calls | sed -n 1p)" = "/sbin/pfctl -a com.apple/260.TPOptimizer -F all" ] && [ "$(calls | wc -l | tr -d ' ')" = "3" ] && ok "qos clear vacía solo su ancla y borra sus dos tuberías" || bad "qos clear" "salida $c $(calls | tr '\n' '|')"
reset; FAILTOOL=pfctl; run qos clear >/dev/null 2>&1; [ $? -eq 65 ] && ok "qos clear dice que falló si pfctl falla" || bad "qos clear con pfctl roto" "$?"
nope "qos clear no admite argumentos" qos clear 192.168.2.4
nope "qos sin verbo se rechaza" qos

good "awdl down llama exactamente a ifconfig awdl0 down" awdl down
[ "$(calls)" = "/sbin/ifconfig awdl0 down" ] && ok "awdl down solo toca awdl0" || bad "awdl down llamadas" "$(calls)"
good "awdl up" awdl up
for a in "" sideways DOWN "down en0" en0; do nope "awdl rechaza «$a»" awdl $a; done

cat > "$T/p.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>com.ejemplo.demonio</string></dict></plist>
PL
reset; cp "$T/p.plist" "$T/daemons/com.ejemplo.demonio.plist"
run launch sleep com.ejemplo.demonio >/dev/null 2>&1; c=$?
has "launchctl bootout system/com.ejemplo.demonio" && has "launchctl disable system/com.ejemplo.demonio" && [ $c -eq 0 ] && ok "launch sleep apaga un demonio del sistema" || bad "launch sleep" "salida $c $(calls)"
reset; cp "$T/p.plist" "$T/agents/com.ejemplo.demonio.plist"
run launch sleep com.ejemplo.demonio >/dev/null 2>&1; has "disable gui/$UIDN/com.ejemplo.demonio" && ok "un agente de usuario se apaga en su dominio gui/UID" || bad "launch agente" "$(calls)"
nopeK "launch sleep rechaza una etiqueta que no existe" launch sleep com.ejemplo.inexistente
nope "launch rechaza etiquetas de Apple" launch sleep com.apple.Finder
nope "launch rechaza una etiqueta con ruta" launch sleep ../etc/passwd
nope "launch rechaza una etiqueta con espacio" launch sleep "com.ejemplo demonio"
nope "launch rechaza una acción desconocida" launch explotar com.ejemplo.demonio
reset; cp "$T/p.plist" "$T/daemons/com.ejemplo.demonio.plist"
run launch wake com.ejemplo.demonio "$T/daemons/com.ejemplo.demonio.plist" >/dev/null 2>&1; has "launchctl enable system/com.ejemplo.demonio" && has "launchctl bootstrap system" && ok "launch wake despierta un plist que está en la carpeta permitida" || bad "launch wake" "$(calls)"
reset; mkdir -p "$T/fuera"; cp "$T/p.plist" "$T/fuera/x.plist"
nopeK "launch wake rechaza un plist fuera de las carpetas de launchd" launch wake com.ejemplo.demonio "$T/fuera/x.plist"
reset; ln -sf "$T/fuera/x.plist" "$T/daemons/escape.plist"
nopeK "launch wake rechaza un enlace que escapa de la carpeta" launch wake com.ejemplo.demonio "$T/daemons/escape.plist"
reset; cp "$T/p.plist" "$T/daemons/otra.plist"
nopeK "launch wake rechaza si la etiqueta no coincide con el plist" launch wake com.ejemplo.distinta "$T/daemons/otra.plist"
reset; cp "$T/p.plist" "$T/agents/com.ejemplo.demonio.plist"
run launch remove com.ejemplo.demonio "$T/agents/com.ejemplo.demonio.plist" >/dev/null 2>&1; c=$?
[ $c -eq 0 ] && [ ! -e "$T/agents/com.ejemplo.demonio.plist" ] && [ -e "$T/home/.Trash/com.ejemplo.demonio.plist" ] && ok "launch remove manda el plist a la Papelera del usuario" || bad "launch remove" "salida $c"
cp "$T/p.plist" "$T/agents/com.ejemplo.demonio.plist"; run launch remove com.ejemplo.demonio "$T/agents/com.ejemplo.demonio.plist" >/dev/null 2>&1
[ -e "$T/home/.Trash/com.ejemplo.demonio 2.plist" ] && ok "si ya hay uno con ese nombre en la Papelera, no lo pisa" || bad "launch remove duplicado" "$(ls "$T/home/.Trash")"
reset; cp "$T/p.plist" "$T/agents/com.ejemplo.demonio.plist"
env TP_T_DAEMONS="$T/daemons" TP_T_AGENTS="$T/agents" TP_T_HOME="$T/home" TP_T_CALLS="$T/calls" TP_T_AUDIT="$T/audit" SUDO_UID=0 "$BIN" launch remove com.ejemplo.demonio "$T/agents/com.ejemplo.demonio.plist" >/dev/null 2>&1
[ $? -eq 65 ] && [ -e "$T/agents/com.ejemplo.demonio.plist" ] && ok "launch remove se niega si quien pide es root (UID 0)" || bad "launch remove root" ""

mkapp() { mkdir -p "$T/apps/$1.app/Contents/MacOS"; printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>' "$2" > "$T/apps/$1.app/Contents/Info.plist"; printf 'x' > "$T/apps/$1.app/Contents/MacOS/$1"; }
reset; mkapp Real com.fake.real
run uninstall "$T/apps/Real.app" >/dev/null 2>&1; c=$?
[ $c -eq 0 ] && [ ! -e "$T/apps/Real.app" ] && [ -e "$T/home/.Trash/Real.app/Contents/Info.plist" ] && ok "uninstall manda una app de /Applications a la Papelera del usuario" || bad "uninstall válido" "salida $c"
[ -z "$(find "$T/home/.Trash/Real.app" ! -user "$UIDN")" ] && ok "todo lo que entra a la Papelera queda a nombre del usuario, para que vaciarla no pida contraseña" || bad "uninstall dueño" "$(find "$T/home/.Trash/Real.app" ! -user "$UIDN" | head -2)"
mkapp Real com.fake.real; run uninstall "$T/apps/Real.app" >/dev/null 2>&1
[ -e "$T/home/.Trash/Real 2.app" ] && ok "uninstall no pisa lo que ya hay en la Papelera" || bad "uninstall duplicado" "$(ls "$T/home/.Trash")"
reset; mkapp Real com.fake.real; mkapp Apple com.apple.Safari; mkdir -p "$T/apps/Vacia.app/Contents"; mkdir -p "$T/apps/sub"; mkapp Real com.fake.real; mkapp sub/Anidada com.fake.nested 2>/dev/null
nopeK "uninstall rechaza una ruta relativa" uninstall Real.app
nopeK "uninstall rechaza una app fuera de /Applications" uninstall /tmp/Otra.app
nopeK "uninstall rechaza una app dentro de una subcarpeta" uninstall "$T/apps/sub/Anidada.app"
nopeK "uninstall rechaza algo que no termina en .app" uninstall "$T/apps/Real.app/Contents"
nopeK "uninstall rechaza subir de carpeta con .." uninstall "$T/apps/../apps/Real.app"
nopeK "uninstall rechaza las apps de Apple" uninstall "$T/apps/Apple.app"
nopeK "uninstall rechaza una app sin Info.plist legible" uninstall "$T/apps/Vacia.app"
nopeK "uninstall rechaza más de una ruta" uninstall "$T/apps/Real.app" "$T/apps/Apple.app"
nopeK "uninstall exige una ruta" uninstall
ln -sfn "$T/apps/Real.app" "$T/apps/Enlace.app"
nopeK "uninstall rechaza un enlace simbólico a una app" uninstall "$T/apps/Enlace.app"
reset; mkapp Real com.fake.real
env TP_T_APPS="$T/apps" TP_T_HOME="$T/home" TP_T_CALLS="$T/calls" TP_T_AUDIT="$T/audit" SUDO_UID=0 "$BIN" uninstall "$T/apps/Real.app" >/dev/null 2>&1
[ $? -eq 65 ] && [ -e "$T/apps/Real.app" ] && ok "uninstall se niega si quien pide es root (UID 0)" || bad "uninstall root" ""

reset; run awdl down >/dev/null 2>&1; run awdl sideways >/dev/null 2>&1
grep -q "awdl down -> ok" "$T/audit" && grep -q "awdl sideways -> fallo" "$T/audit" && grep -q "uid=$UIDN" "$T/audit" && ok "cada orden queda en el registro con quién la pidió y si salió bien o falló" || bad "registro" "$(cat "$T/audit")"

echo; echo "Resultado: $PASS pasan, $FAIL fallan"
[ $FAIL -eq 0 ] && echo "AYUDANTE: TODO OK" || echo "AYUDANTE: HAY FALLAS"
[ $FAIL -eq 0 ]
