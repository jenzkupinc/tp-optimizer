<p align="center">
  <img src="assets/banner.svg" alt="TP Optimizer" width="100%">
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-0b3b4a?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-127c8c?style=for-the-badge">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-Swift%205-f08a24?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="Gratis" src="https://img.shields.io/badge/Precio-GRATIS-2ea44f?style=for-the-badge">
  <img alt="MIT" src="https://img.shields.io/badge/Licencia-MIT-lightgrey?style=for-the-badge">
</p>

<h3 align="center">Un solo toque para dejar tu Mac ligera, y un modo juego para el iPad que usa tu Wi-Fi compartido.</h3>

---

## 🥇 1 · Boost

Barre cachés viejas, baja la prioridad de lo pesado en segundo plano y te muestra **antes y después con números de macOS**. Nada se borra para siempre: todo va a la Papelera.

**Boost profundo** además purga la caché de memoria y renueva el DNS.

> 📏 Medido en un Mac mini con 16 GB: tras un Boost profundo la memoria **libre al instante** subió de **0,12 GB a 3,02 GB**. El porcentaje de «RAM libre» casi no cambia porque macOS ya cuenta la caché como libre; por eso la app muestra la fila **Libre al instante**.

## 🥈 2 · Modo juego

Pensado para jugar desde un iPad conectado a **Compartir Internet** de tu Mac.

| | |
|---|---|
| 🟢 **Tramos separados** | iPad ↔ Mac (Wi-Fi), Mac ↔ router (cable) y Mac ↔ internet, cada uno medido por aparte |
| 🟡 **Qué cambia al jugar** | Prioridad baja a lo pesado, apps de red dormidas, Time Machine en pausa, AirDrop apagado, límite a los demás equipos |
| 🔴 **Honesto con el resultado** | «Arreglar ahora» mide los saltos antes y después y te dice si no mejoraron |

Al terminar la sesión todo vuelve a como estaba.

## 🥉 3 · Todo lo demás

| Sección | Para qué sirve |
|---|---|
| **Monitor** | Procesos, memoria, CPU y quién usa la red |
| **Seguridad** | Firewall, cifrado de disco, SIP, Gatekeeper y accesos remotos |
| **Limpieza profunda** · **Archivos grandes** · **Duplicados** | Encuentra y envía a la Papelera |
| **Discos y respaldo** | Respaldo a un disco externo |
| **Perfiles** · **Energía** | Qué apps duermen y qué impide que la Mac descanse |
| **Red y router** | DNS, equipos conectados, diagnóstico del router |
| **Arranque automático** · **Desinstalar apps** | Control de lo que se abre solo y de lo que dejan las apps |
| **Scripts y Telegram** | Tus propios scripts y avisos por Telegram (opcional) |

## 🚀 Instalación en 3 pasos

**Requisitos:** macOS 26 o superior, Apple Silicon y Xcode Command Line Tools (`xcode-select --install`).

1. **Crea un certificado de firma local.** Abre *Acceso a Llaveros → Asistente de certificados → Crear un certificado*, nombre `TP Optimizer Local`, tipo **Firma de código**.
2. **Compila e instala:**
   ```bash
   git clone https://github.com/jenzkupinc/tp-optimizer.git
   cd tp-optimizer
   bash build.sh
   ```
3. **Abre** `TP Optimizer` desde *Aplicaciones*. La primera vez que uses una función con privilegios te pide la contraseña de administrador una sola vez.

Variables opcionales de `build.sh`: `SIGN_IDENTITY` (otro nombre de certificado) e `INSTALL_DIR` (otra carpeta).

## 🔐 Privacidad y seguridad

- **Sin telemetría.** La app no envía nada afuera. Telegram solo funciona si tú pones tu propio token.
- **Ayudante con privilegios.** Para tareas como el firewall, el DNS o el límite de ancho de banda, la app instala `app.tpoptimizer.root` y una regla `sudoers` sin contraseña **solo para ese binario**. Cada operación valida sus argumentos y el ayudante solo se actualiza si el nuevo binario está firmado con tu mismo certificado.
- **Límite conocido:** la regla `sudoers` no restringe qué argumentos se pasan, así que cualquier programa de tu usuario puede invocar las operaciones del ayudante. Instálalo solo en una Mac que controles.
- Para quitar el ayudante: borra `/Library/PrivilegedHelperTools/app.tpoptimizer.root` y `/etc/sudoers.d/tp-optimizer`.

## ✅ Estado

Versión `1.0`. Probada a mano en un Mac mini con macOS 26: **Boost, Boost profundo y Modo juego**. El resto de las secciones compila y abre, pero no tiene pruebas manuales completas. Si algo falla, abre un *issue* con el texto del error.

## 🧱 Estructura

```
*.swift          interfaz y lógica de cada sección
helper/          ayudante con privilegios (tp-root.swift)
Resources/       icono y logo
build.sh         compila, firma e instala
```

## 📄 Licencia

[MIT](LICENSE) · Hecho por **TRIPLAN**.
