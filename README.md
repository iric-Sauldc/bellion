# bellion

TUI interactiva que se activa automáticamente cuando escribes un comando
no instalado. Busca en **apt**, **snap** y **flatpak** simultáneamente.

## Instalación

```bash
unzip bellion.zip && cd bellion
bash install.sh
```

El instalador:
- Detecta y resuelve problemas de `python3-venv` automáticamente
- Crea un venv aislado — no toca el Python del sistema
- Instala el hook en `/usr/lib/command-not-found` sin tocar dotfiles
- Soporta bash, zsh y fish automáticamente
- Verifica cada paso antes de continuar

## Uso

No necesitas hacer nada. Al escribir un comando inexistente, bellion aparece solo:

```
$ gimp
  'gimp' no encontrado — buscando paquetes disponibles...
  [TUI se abre automáticamente]
```

## Atajos

| Tecla     | Acción                  |
|-----------|-------------------------|
| `↑ ↓`    | Navegar paquetes        |
| `Enter`   | Instalar seleccionado   |
| `i`       | Instalar seleccionado   |
| `Tab`     | Enfocar tabla           |
| `Escape`  | Limpiar búsqueda        |
| `F5`      | Buscar de nuevo         |
| `Ctrl+Q`  | Salir                   |

## Desinstalación

```bash
sudo bash uninstall.sh
```

Restaura `/usr/lib/command-not-found` al estado original. Si no hay backup,
reinstala el paquete `command-not-found` desde apt automáticamente.
No modifica ningún dotfile del usuario.

## Compatibilidad

- Ubuntu 22.04, 23.04, 24.04, 25.04+
- Debian 11, 12+
- Python 3.8 – 3.13
- Shells: bash, zsh, fish
