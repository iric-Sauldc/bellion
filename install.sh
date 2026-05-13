#!/usr/bin/env bash
# bellion — instalador v2.1
# NO modifica .bashrc ni .zshrc ni ningún dotfile del usuario

set -euo pipefail

INSTALL_DIR="/usr/local/share/bellion"
VENV_DIR="$INSTALL_DIR/venv"
BIN_BELLION="/usr/local/bin/bellion"
CNF_ORIG="/usr/lib/command-not-found"
CNF_BACKUP="/usr/lib/command-not-found.orig"
ZSH_HOOK_DIR="/etc/zshrc.d"
ZSH_HOOK_FILE="$ZSH_HOOK_DIR/bellion-command-not-found.zsh"
ZSH_GLOBAL_RC="/etc/zshrc"          # fallback si no existe zshrc.d
FISH_FUNC_DIR="/usr/share/fish/vendor_functions.d"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERRORS=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; ERRORS=$((ERRORS+1)); }
err()  { echo -e "  ${RED}✗${RESET} $*"; }
step() { echo -e "\n${BOLD}→ $*${RESET}"; }

if [[ $EUID -ne 0 ]]; then
    echo "Este instalador necesita sudo para instalar en /usr/local/"
    exec sudo bash "$0" "$@"
fi

echo -e "${BOLD}"
echo "╔══════════════════════════════════════╗"
echo "║       bellion — instalador v2.1      ║"
echo "╚══════════════════════════════════════╝"
echo -e "${RESET}"

# ─────────────────────────────────────────────────────────────────
# PASO 1 — Python y venv
# ─────────────────────────────────────────────────────────────────
step "Verificando Python y venv..."

if ! command -v python3 &>/dev/null; then
    err "python3 no encontrado. Instala con: sudo apt install python3"
    exit 1
fi

PY_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || {
    err "No se pudo determinar la versión de Python"; exit 1
}
ok "Python $PY_VERSION detectado"

VENV_TEST=$(mktemp -d)
VENV_OK=false
if python3 -m venv "$VENV_TEST" --without-pip 2>/dev/null && [[ -x "$VENV_TEST/bin/python3" ]]; then
    VENV_OK=true
fi
rm -rf "$VENV_TEST"

if [[ "$VENV_OK" == false ]]; then
    step "Instalando python${PY_VERSION}-venv..."
    if apt-get install -y "python${PY_VERSION}-venv" -q 2>/dev/null; then
        ok "python${PY_VERSION}-venv instalado"
    elif apt-get install -y python3-venv python3-full -q 2>/dev/null; then
        ok "python3-full instalado como fallback"
    else
        err "No se pudo instalar venv para Python $PY_VERSION"; exit 1
    fi
    VENV_TEST2=$(mktemp -d)
    if ! python3 -m venv "$VENV_TEST2" --without-pip 2>/dev/null || [[ ! -x "$VENV_TEST2/bin/python3" ]]; then
        rm -rf "$VENV_TEST2"; err "venv sigue sin funcionar"; exit 1
    fi
    rm -rf "$VENV_TEST2"; ok "venv verificado correctamente"
else
    ok "venv funciona correctamente"
fi

# ─────────────────────────────────────────────────────────────────
# PASO 2 — Venv y dependencias
# ─────────────────────────────────────────────────────────────────
step "Creando entorno virtual Python..."
mkdir -p "$INSTALL_DIR"

if [[ -d "$VENV_DIR" ]]; then
    warn "Venv existente encontrado, eliminando para crear uno limpio..."
    rm -rf "$VENV_DIR"
fi

python3 -m venv "$VENV_DIR" 2>/dev/null || { err "Falló la creación del venv"; exit 1; }
ok "Venv creado en $VENV_DIR"

[[ -x "$VENV_DIR/bin/pip" ]] || { err "pip no encontrado en el venv"; exit 1; }

step "Instalando dependencias (textual, rich)..."
"$VENV_DIR/bin/pip" install --upgrade pip --quiet 2>/dev/null || true
"$VENV_DIR/bin/pip" install textual rich --quiet 2>/dev/null || {
    warn "Reintentando con output visible..."
    "$VENV_DIR/bin/pip" install textual rich || { err "No se pudo instalar textual/rich"; exit 1; }
}
"$VENV_DIR/bin/python3" -c "import textual, rich" 2>/dev/null || {
    err "Las dependencias no importan correctamente"; exit 1
}
ok "textual y rich instalados y verificados"

# ─────────────────────────────────────────────────────────────────
# PASO 3 — apt-file (opcional)
# ─────────────────────────────────────────────────────────────────
step "Verificando apt-file..."
if ! command -v apt-file &>/dev/null; then
    if apt-get install -y apt-file -q 2>/dev/null; then
        ok "apt-file instalado"
        apt-file update -q 2>/dev/null && ok "apt-file actualizado" || \
            warn "apt-file update falló — se usará apt-cache como fallback"
    else
        warn "apt-file no disponible — se usará apt-cache como fallback"
    fi
else
    ok "apt-file disponible"
fi

# ─────────────────────────────────────────────────────────────────
# PASO 4 — Instalar bellion.py y launcher
# ─────────────────────────────────────────────────────────────────
step "Instalando bellion..."

[[ -f "$SCRIPT_DIR/bellion.py" ]] || { err "bellion.py no encontrado en $SCRIPT_DIR"; exit 1; }

cp "$SCRIPT_DIR/bellion.py" "$INSTALL_DIR/bellion.py"
chmod 644 "$INSTALL_DIR/bellion.py"

"$VENV_DIR/bin/python3" -m py_compile "$INSTALL_DIR/bellion.py" 2>/dev/null || {
    err "bellion.py tiene errores de sintaxis"; exit 1
}

printf '#!/usr/bin/env bash\nexec %s %s "$@"\n' \
    "$VENV_DIR/bin/python3" "$INSTALL_DIR/bellion.py" > "$BIN_BELLION"
chmod 755 "$BIN_BELLION"
ok "bellion instalado en $BIN_BELLION"

# ─────────────────────────────────────────────────────────────────
# PASO 5 — Hook bash via /usr/lib/command-not-found
#
# NOTA IMPORTANTE sobre bash:
#   /etc/bash.bashrc llama al handler así:
#     /usr/lib/command-not-found -- "$1"
#   El '--' es un separador POSIX. Nuestro hook lo ignora correctamente.
#   bellion.py también filtra '--' en _parse_command().
# ─────────────────────────────────────────────────────────────────
step "Configurando hook para bash..."

if [[ -f "$CNF_ORIG" ]] && [[ ! -f "$CNF_BACKUP" ]]; then
    cp "$CNF_ORIG" "$CNF_BACKUP"
    chmod --reference="$CNF_ORIG" "$CNF_BACKUP" 2>/dev/null || chmod 755 "$CNF_BACKUP"
    ok "Original respaldado en $CNF_BACKUP"
elif [[ -f "$CNF_BACKUP" ]]; then
    ok "Respaldo ya existía en $CNF_BACKUP"
else
    warn "/usr/lib/command-not-found no existe — el hook se instalará de todas formas"
fi

cat > "$CNF_ORIG" << 'HOOK'
#!/usr/bin/env bash
# bellion hook — command-not-found handler v2.1
# Original respaldado en: /usr/lib/command-not-found.orig
#
# bash llama a este archivo con: /usr/lib/command-not-found -- <cmd>
# El '--' es un separador POSIX estándar que debemos ignorar.
#
# Árbol de decisión:
#   1. Filtrar '--' y obtener el comando real
#   2. Sin CMD o ruta absoluta  → fallback original
#   3. Sin terminal interactiva → fallback silencioso
#   4. bellion disponible       → invocar bellion
#   5. venv intacto, sin launcher → auto-reparar e invocar
#   6. sin permisos             → ejecutar directo desde venv
#   7. todo ausente             → aviso claro + fallback

readonly BELLION_BIN="/usr/local/bin/bellion"
readonly BELLION_PY="/usr/local/share/bellion/bellion.py"
readonly BELLION_VENV_PY="/usr/local/share/bellion/venv/bin/python3"
readonly CNF_FALLBACK="/usr/lib/command-not-found.orig"

# Filtrar '--' de los argumentos (bash lo inyecta como separador)
CMD=""
for arg in "$@"; do
    [[ "$arg" == "--" ]] && continue
    CMD="$arg"
    break
done

_fallback() {
    if [[ -x "$CNF_FALLBACK" ]]; then
        exec "$CNF_FALLBACK" "$@"
    fi
    [[ -n "${CMD}" ]] && echo "${CMD}: comando no encontrado" >&2
    exit 127
}

[[ -z "$CMD" ]] && exit 127

# Rutas absolutas o relativas → delegar
if [[ "$CMD" == */* ]]; then
    _fallback "$@"
fi

# Sin terminal interactiva (pipe, script, cron, subshell)
if [[ ! -t 1 ]]; then
    _fallback "$@"
fi

_announce() {
    echo ""
    echo "  '${CMD}' no encontrado — buscando paquetes disponibles..."
    echo ""
}

_repair_launcher() {
    [[ -x "$BELLION_VENV_PY" ]] && [[ -f "$BELLION_PY" ]] || return 1
    local tmp
    tmp=$(mktemp) || return 1
    printf '#!/usr/bin/env bash\nexec %s %s "$@"\n' "$BELLION_VENV_PY" "$BELLION_PY" > "$tmp"
    mv "$tmp" "$BELLION_BIN" 2>/dev/null && chmod 755 "$BELLION_BIN" 2>/dev/null && return 0
    rm -f "$tmp"; return 1
}

if [[ -x "$BELLION_BIN" ]]; then
    _announce
    "$BELLION_BIN" "$CMD"

elif [[ -x "$BELLION_VENV_PY" ]] && [[ -f "$BELLION_PY" ]]; then
    if _repair_launcher 2>/dev/null; then
        _announce
        "$BELLION_BIN" "$CMD"
    else
        _announce
        echo "  (aviso: para reparar el launcher: sudo bellion-repair)" >&2
        "$BELLION_VENV_PY" "$BELLION_PY" "$CMD"
    fi

else
    echo "" >&2
    echo "  '${CMD}': comando no encontrado" >&2
    if [[ -d "/usr/local/share/bellion" ]]; then
        echo "" >&2
        echo "  ⚠  bellion parece incompleto. Reinstala: sudo bash install.sh" >&2
        echo "     O repara: sudo bellion-repair" >&2
    fi
    echo "" >&2
    _fallback "$@"
fi

exit 127
HOOK

chmod 755 "$CNF_ORIG"
grep -q "bellion" "$CNF_ORIG" 2>/dev/null && ok "Hook bash activo" || {
    err "El hook bash no se escribió correctamente"; ERRORS=$((ERRORS+1))
}

# ─────────────────────────────────────────────────────────────────
# PASO 6 — Hook zsh (global, sin tocar .zshrc del usuario)
#
# Zsh no usa /usr/lib/command-not-found directamente.
# Define la función command_not_found_handler en configuración global.
# Orden de carga zsh: /etc/zshenv → /etc/zprofile → /etc/zshrc → /etc/zlogin
# Usamos /etc/zshrc.d/ si existe, si no /etc/zshrc (append idempotente).
# ─────────────────────────────────────────────────────────────────
step "Configurando hook para zsh..."

ZSH_HOOK_CONTENT='
# ── bellion command_not_found_handler ──────────────────────────
# Instalado por bellion. Para desinstalar: sudo bash uninstall.sh
if [[ -o interactive ]]; then
    command_not_found_handler() {
        local cmd="$1"
        local bellion_bin="/usr/local/bin/bellion"
        local bellion_py="/usr/local/share/bellion/bellion.py"
        local bellion_venv="/usr/local/share/bellion/venv/bin/python3"

        # Ignorar rutas absolutas/relativas
        if [[ "$cmd" == */* ]]; then
            print -u2 -- "${cmd}: no such file or directory"
            return 127
        fi

        if [[ -x "$bellion_bin" ]]; then
            echo ""
            echo "  '"'"'${cmd}'"'"' no encontrado — buscando paquetes disponibles..."
            echo ""
            "$bellion_bin" "$cmd"

        elif [[ -x "$bellion_venv" ]] && [[ -f "$bellion_py" ]]; then
            echo ""
            echo "  '"'"'${cmd}'"'"' no encontrado — buscando paquetes disponibles..."
            echo "  (aviso: para reparar: sudo bellion-repair)"
            echo ""
            "$bellion_venv" "$bellion_py" "$cmd"

        else
            print -u2 -- "${cmd}: command not found"
        fi
        return 127
    }
fi
# ── fin bellion ─────────────────────────────────────────────────
'

ZSH_INSTALLED=false

if command -v zsh &>/dev/null; then
    # Preferir /etc/zshrc.d/ (directorio de snippets, limpio)
    if [[ -d "$ZSH_HOOK_DIR" ]]; then
        echo "$ZSH_HOOK_CONTENT" > "$ZSH_HOOK_FILE"
        chmod 644 "$ZSH_HOOK_FILE"
        ok "Hook zsh instalado en $ZSH_HOOK_FILE"
        ZSH_INSTALLED=true

    # Fallback: añadir a /etc/zshrc si existe (idempotente)
    elif [[ -f "$ZSH_GLOBAL_RC" ]]; then
        if ! grep -q "bellion command_not_found_handler" "$ZSH_GLOBAL_RC" 2>/dev/null; then
            echo "$ZSH_HOOK_CONTENT" >> "$ZSH_GLOBAL_RC"
            ok "Hook zsh añadido a $ZSH_GLOBAL_RC"
        else
            ok "Hook zsh ya presente en $ZSH_GLOBAL_RC"
        fi
        ZSH_INSTALLED=true

    # Fallback: crear /etc/zshrc.d/ y usarlo
    else
        mkdir -p "$ZSH_HOOK_DIR"
        echo "$ZSH_HOOK_CONTENT" > "$ZSH_HOOK_FILE"
        chmod 644 "$ZSH_HOOK_FILE"
        # Asegurarse de que /etc/zshrc carga el directorio
        if [[ ! -f "$ZSH_GLOBAL_RC" ]] || ! grep -q "zshrc.d" "$ZSH_GLOBAL_RC" 2>/dev/null; then
            cat >> "$ZSH_GLOBAL_RC" << 'ZSHRC_LOADER'

# Cargar snippets de /etc/zshrc.d/
if [[ -d /etc/zshrc.d ]]; then
    for f in /etc/zshrc.d/*.zsh(N); do
        source "$f"
    done
fi
ZSHRC_LOADER
            ok "Loader de /etc/zshrc.d añadido a $ZSH_GLOBAL_RC"
        fi
        ok "Hook zsh instalado en $ZSH_HOOK_FILE"
        ZSH_INSTALLED=true
    fi
else
    ok "zsh no detectado — hook omitido"
fi

[[ "$ZSH_INSTALLED" == false ]] && warn "Hook zsh no instalado — zsh no disponible"

# ─────────────────────────────────────────────────────────────────
# PASO 7 — Hook fish
# ─────────────────────────────────────────────────────────────────
if command -v fish &>/dev/null; then
    step "Fish detectado — instalando fish_command_not_found..."
    mkdir -p "$FISH_FUNC_DIR"
    cat > "$FISH_FUNC_DIR/fish_command_not_found.fish" << 'FISH'
function fish_command_not_found
    set cmd $argv[1]
    set bellion_bin  "/usr/local/bin/bellion"
    set bellion_py   "/usr/local/share/bellion/bellion.py"
    set bellion_venv "/usr/local/share/bellion/venv/bin/python3"

    # Ignorar rutas absolutas/relativas
    if string match -q '*/*' $cmd
        __fish_default_command_not_found_handler $argv
        return
    end

    if test -x $bellion_bin
        echo ""
        echo "  '$cmd' no encontrado — buscando paquetes disponibles..."
        echo ""
        $bellion_bin $cmd

    else if test -x $bellion_venv; and test -f $bellion_py
        echo ""
        echo "  '$cmd' no encontrado — buscando paquetes disponibles..."
        echo "  (aviso: para reparar: sudo bellion-repair)"
        echo ""
        $bellion_venv $bellion_py $cmd

    else
        echo "" >&2
        echo "  '$cmd': comando no encontrado" >&2
        echo "" >&2
        __fish_default_command_not_found_handler $argv
    end
end
FISH
    ok "fish_command_not_found instalado en $FISH_FUNC_DIR"
fi

# ─────────────────────────────────────────────────────────────────
# PASO 8 — bellion-repair
# ─────────────────────────────────────────────────────────────────
step "Instalando bellion-repair..."

cat > "/usr/local/bin/bellion-repair" << 'REPAIR'
#!/usr/bin/env bash
set -euo pipefail
BELLION_BIN="/usr/local/bin/bellion"
BELLION_PY="/usr/local/share/bellion/bellion.py"
BELLION_VENV_PY="/usr/local/share/bellion/venv/bin/python3"

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

[[ -x "$BELLION_VENV_PY" ]] || { echo "✗ Venv no encontrado. Reinstala completamente." >&2; exit 1; }
[[ -f "$BELLION_PY" ]]      || { echo "✗ bellion.py no encontrado. Reinstala completamente." >&2; exit 1; }

printf '#!/usr/bin/env bash\nexec %s %s "$@"\n' "$BELLION_VENV_PY" "$BELLION_PY" > "$BELLION_BIN"
chmod 755 "$BELLION_BIN"
echo "✓ Launcher reconstruido en $BELLION_BIN"
REPAIR
chmod 755 "/usr/local/bin/bellion-repair"
ok "bellion-repair instalado"

# ─────────────────────────────────────────────────────────────────
# PASO 9 — Verificación final
# ─────────────────────────────────────────────────────────────────
step "Verificación final..."
VERIFY_ERRORS=0

check() {
    local desc="$1"; local cond="$2"; local is_warn="${3:-}"
    if eval "$cond" 2>/dev/null; then
        ok "$desc"
    elif [[ -n "$is_warn" ]]; then
        warn "$desc"
    else
        err "$desc"; VERIFY_ERRORS=$((VERIFY_ERRORS+1))
    fi
}

check "bellion.py presente"          "[[ -f '$INSTALL_DIR/bellion.py' ]]"
check "launcher ejecutable"          "[[ -x '$BIN_BELLION' ]]"
check "bellion-repair OK"            "[[ -x '/usr/local/bin/bellion-repair' ]]"
check "venv presente"                "[[ -d '$VENV_DIR' ]]"
check "Python en venv OK"            "[[ -x '$VENV_DIR/bin/python3' ]]"
check "Dependencias OK"              "'$VENV_DIR/bin/python3' -c 'import textual, rich'"
check "Hook bash activo"             "grep -q bellion '$CNF_ORIG'"
check "Backup original OK"           "[[ -f '$CNF_BACKUP' ]]"  "warn"

TOTAL_ERRORS=$((ERRORS + VERIFY_ERRORS))

# Detectar shells instalados para el resumen
SHELLS_SUPPORTED=""
command -v bash &>/dev/null && SHELLS_SUPPORTED+="bash "
command -v zsh  &>/dev/null && SHELLS_SUPPORTED+="zsh "
command -v fish &>/dev/null && SHELLS_SUPPORTED+="fish "

echo ""
if [[ $TOTAL_ERRORS -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ✓ Instalación completa y verificada                 ║"
    echo "║                                                      ║"
    printf "║  Shells: %-43s║\n" "$SHELLS_SUPPORTED"
    echo "║  Automático: escribe cualquier cmd inexistente       ║"
    echo "║  Manual:     bellion ffmpeg                          ║"
    echo "║  Reparar:    sudo bellion-repair                     ║"
    echo "║  Desinstalar: sudo bash uninstall.sh                 ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
else
    echo -e "${YELLOW}${BOLD}"
    printf "╔══════════════════════════════════════════════════════╗\n"
    printf "║  ⚠ Instalación con %-2d advertencia(s)                ║\n" "$TOTAL_ERRORS"
    printf "║    Revisa los mensajes arriba                        ║\n"
    printf "╚══════════════════════════════════════════════════════╝\n"
    echo -e "${RESET}"
fi
