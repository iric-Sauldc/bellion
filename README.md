# bellion

> ⚠️ **En desarrollo activo — actualmente funciona en bash. Soporte para zsh y fish en progreso.**

TUI interactiva que se activa automáticamente cuando escribes un comando no instalado en Linux. Busca paquetes en **apt**, **snap** y **flatpak** al mismo tiempo y te permite instalarlos sin salir de la terminal.

![Estado](https://img.shields.io/badge/estado-beta-yellow) ![Shell](https://img.shields.io/badge/shell-bash-green) ![Python](https://img.shields.io/badge/python-3.8%2B-blue) ![Licencia](https://img.shields.io/badge/licencia-MIT-lightgrey)

---

## ¿Qué hace?

En lugar de ver esto:

```
$ ffmpeg
bash: ffmpeg: command not found
```

Ves esto:

```
$ ffmpeg
  'ffmpeg' no encontrado — buscando paquetes disponibles...

  ┌────────────────────────────────────────────────────────┐
  │  🔍  ffmpeg                                            │
  │  ──────────────────────────────────────────────────── │
  │  📦 APT   ffmpeg      7:6.1-3    /usr/bin/ffmpeg  ... │
  │  📦 APT   ffmpeg-doc  7:6.1-3    ffmpeg           ... │
  │  🔲 SNAP  ffmpeg      ...                             │
  └────────────────────────────────────────────────────────┘
```

Seleccionas el paquete con las flechas y presionas `Enter` para instalarlo.

---

## Compatibilidad

| | Estado |
|---|---|
| **bash** | ✅ Funciona |
| zsh | 🚧 En progreso |
| fish | 🚧 En progreso |
| **Ubuntu 22.04 / 24.04** | ✅ Probado |
| **Debian 11 / 12** | ✅ Probado |
| Ubuntu 25.04+ | 🔲 Sin probar |
| **Python 3.8 – 3.13** | ✅ Funciona |
| **apt** | ✅ Funciona |
| snap | 🔲 Experimental |
| flatpak | 🔲 Experimental |

---

## Instalación

Clona el repositorio e instala con sudo:

```bash
git clone https://github.com/iric-Sauldc/bellion.git
cd bellion
sudo bash install.sh
```

El instalador:
- Detecta y resuelve automáticamente problemas de `python3-venv`
- Crea un entorno virtual aislado — no toca el Python del sistema
- Instala el hook en `/usr/lib/command-not-found` sin modificar `.bashrc` ni ningún dotfile
- Instala `bellion-repair` para recuperación rápida si algo falla
- Verifica cada paso antes de continuar

---

## Uso

No necesitas configurar nada. Escribe cualquier comando que no tengas instalado:

```bash
$ gimp
  'gimp' no encontrado — buscando paquetes disponibles...
```

O lánzalo manualmente para buscar cualquier paquete:

```bash
bellion ffmpeg
bellion node
bellion gimp
```

### Atajos de teclado

| Tecla | Acción |
|---|---|
| `↑` `↓` | Navegar entre paquetes |
| `Enter` | Instalar paquete seleccionado |
| `i` | Instalar paquete seleccionado |
| `Tab` | Alternar foco búsqueda / tabla |
| `Escape` | Limpiar búsqueda |
| `F5` | Repetir búsqueda |
| `Ctrl+Q` | Salir |

---

## Desinstalación

```bash
sudo bash uninstall.sh
```

Restaura `/usr/lib/command-not-found` al estado original (desde backup o reinstalando el paquete desde apt). No modifica ningún dotfile del usuario.

---

## Reparación

Si el launcher desaparece pero la instalación sigue en disco:

```bash
sudo bellion-repair
```

El hook también intenta auto-reparar el launcher automáticamente cuando detecta que el venv sigue intacto.

---

## Cómo funciona

bellion se engancha en el mecanismo estándar de bash para comandos no encontrados. Cuando escribes un comando inexistente, bash llama a `/usr/lib/command-not-found`. El instalador reemplaza ese archivo con un hook propio que lanza la TUI de bellion.

La TUI está construida con [Textual](https://github.com/Textualize/textual) y busca en paralelo en apt, snap y flatpak. Corre en un entorno virtual Python aislado en `/usr/local/share/bellion/venv`, sin afectar el Python del sistema.

Comportamiento del hook ante distintas situaciones:

| Situación | Comportamiento |
|---|---|
| Todo normal | Lanza bellion directamente |
| Launcher eliminado, venv intacto | Auto-repara el launcher y lanza |
| Sin permisos para reparar | Ejecuta desde el venv directamente |
| Sin terminal interactiva (scripts, cron) | Fallback silencioso al handler original |
| Ruta absoluta (`./foo`, `/usr/bin/foo`) | Delega al handler original |
| Instalación corrupta | Aviso con instrucciones + fallback |

---

## Dependencias

- Python 3.8+
- `python3-venv` (el instalador lo instala si falta)
- [textual](https://github.com/Textualize/textual) y [rich](https://github.com/Textualize/rich) (instalados en el venv automáticamente)
- `apt-file` (opcional, mejora la precisión de búsqueda — el instalador lo instala)

---

## Limitaciones conocidas

- Solo funciona en **bash** por ahora. El soporte para zsh y fish está en desarrollo.
- Requiere distribuciones basadas en Debian/Ubuntu que usen `apt` y el mecanismo `command-not-found`.
- La búsqueda en snap y flatpak puede ser lenta dependiendo de la conexión.
- snap y flatpak están marcados como experimentales — los resultados pueden ser inconsistentes.

---

## Contribuir

El proyecto está en etapa beta. Si encuentras un bug o quieres probar en otras distros o shells, abre un issue con:

- Distribución y versión
- Versión de bash (`bash --version`)
- Versión de Python (`python3 --version`)
- Output completo del error

Las PRs son bienvenidas, en especial para soporte de zsh, fish, y otras distros.

---

## Licencia

MIT — ve el archivo [LICENSE](LICENSE) para más detalles.
