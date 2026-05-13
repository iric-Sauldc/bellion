#!/usr/bin/env bash
# bellion — desinstalador v2.1

set -uo pipefail

CNF_ORIG="/usr/lib/command-not-found"
CNF_BACKUP="/usr/lib/command-not-found.orig"
BIN_BELLION="/usr/local/bin/bellion"
BIN_REPAIR="/usr/local/bin/bellion-repair"
INSTALL_DIR="/usr/local/share/bellion"
ZSH_HOOK_FILE="/etc/zshrc.d/bellion-command-not-found.zsh"
ZSH_GLOBAL_RC="/etc/zshrc"
FISH_HOOK="/usr/share/fish/vendor_functions.d/fish_command_not_found.fish"
ERRORS=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "  ${RED}✗${RESET} $*"; ERRORS=$((ERRORS+1)); }
step() { echo -e "\n${BOLD}→ $*${RESET}"; }

[[ $EUID -ne 0 ]] && { echo "Este desinstalador necesita sudo."; exec sudo bash "$0" "$@"; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════╗"
echo "║      bellion — desinstalador v2.1    ║"
echo "╚══════════════════════════════════════╝"
echo -e "${RESET}"

# ─────────────────────────────────────────────────────────────────
# PASO 1 — Restaurar /usr/lib/command-not-found (bash hook)
# ─────────────────────────────────────────────────────────────────
step "Restaurando hook bash (command-not-found)..."

CNF_IS_OURS=false
[[ -f "$CNF_ORIG" ]] && grep -q "bellion" "$CNF_ORIG" 2>/dev/null && CNF_IS_OURS=true

_install_minimal_cnf() {
    cat > "$CNF_ORIG" << 'MINIMAL'
#!/usr/bin/env python3
import sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
# Filtrar '--' que bash inyecta
cmd = next((a for a in sys.argv[1:] if a != "--"), "")
if cmd:
    print(f"{cmd}: comando no encontrado", file=sys.stderr)
sys.exit(127)
MINIMAL
    chmod 755 "$CNF_ORIG"
    warn "Handler mínimo instalado. Para el original: sudo apt install --reinstall command-not-found"
}

if [[ "$CNF_IS_OURS" == false ]] && [[ ! -f "$CNF_BACKUP" ]]; then
    ok "command-not-found no fue modificado por bellion — nada que restaurar"

elif [[ -f "$CNF_BACKUP" ]]; then
    if grep -q "bellion" "$CNF_BACKUP" 2>/dev/null; then
        err "Backup corrupto (contiene referencias a bellion)"
        rm -f "$CNF_BACKUP"
        apt-get install -y --reinstall command-not-found -q 2>/dev/null && \
            ok "command-not-found reinstalado desde apt" || _install_minimal_cnf
    else
        cp "$CNF_BACKUP" "$CNF_ORIG"
        chmod 755 "$CNF_ORIG"
        rm -f "$CNF_BACKUP"
        ok "command-not-found restaurado desde backup"
    fi

elif [[ "$CNF_IS_OURS" == true ]]; then
    warn "Hook nuestro activo pero sin backup del original"
    apt-get install -y --reinstall command-not-found -q 2>/dev/null && \
        ok "command-not-found reinstalado desde apt" || _install_minimal_cnf
fi

if [[ -f "$CNF_ORIG" ]] && grep -q "bellion" "$CNF_ORIG" 2>/dev/null; then
    err "CRÍTICO: hook de bellion sigue en $CNF_ORIG"
    err "Restauración manual: sudo apt install --reinstall command-not-found"
else
    ok "Hook bash eliminado"
fi

# ─────────────────────────────────────────────────────────────────
# PASO 2 — Eliminar hook zsh
# ─────────────────────────────────────────────────────────────────
step "Eliminando hook zsh..."

# Eliminar archivo en /etc/zshrc.d/ si es nuestro
if [[ -f "$ZSH_HOOK_FILE" ]] && grep -q "bellion" "$ZSH_HOOK_FILE" 2>/dev/null; then
    rm -f "$ZSH_HOOK_FILE"
    ok "Archivo de hook zsh eliminado ($ZSH_HOOK_FILE)"
elif [[ -f "$ZSH_HOOK_FILE" ]]; then
    ok "$ZSH_HOOK_FILE no es de bellion — no tocado"
else
    ok "Archivo de hook zsh no existe"
fi

# Limpiar bloque de bellion en /etc/zshrc si fue añadido ahí
if [[ -f "$ZSH_GLOBAL_RC" ]] && grep -q "bellion command_not_found_handler" "$ZSH_GLOBAL_RC" 2>/dev/null; then
    # Eliminar el bloque entre los marcadores de bellion
    python3 - "$ZSH_GLOBAL_RC" << 'PYREMOVE'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Eliminar bloque entre los marcadores bellion
cleaned = re.sub(
    r'\n# ── bellion command_not_found_handler.*?# ── fin bellion ─+\n',
    '',
    content,
    flags=re.DOTALL
)
if cleaned != content:
    with open(path, 'w') as f:
        f.write(cleaned)
    print(f"  Bloque bellion eliminado de {path}")
else:
    print(f"  No se encontró bloque bellion en {path}")
PYREMOVE
    ok "Hook zsh eliminado de $ZSH_GLOBAL_RC"
fi

# ─────────────────────────────────────────────────────────────────
# PASO 3 — Eliminar hook fish
# ─────────────────────────────────────────────────────────────────
step "Verificando hook fish..."
if [[ -f "$FISH_HOOK" ]]; then
    if grep -q "bellion" "$FISH_HOOK" 2>/dev/null; then
        rm -f "$FISH_HOOK"; ok "Hook fish eliminado"
    else
        ok "$FISH_HOOK no es de bellion — no tocado"
    fi
else
    ok "No hay hook fish que eliminar"
fi

# ─────────────────────────────────────────────────────────────────
# PASO 4 — Eliminar binarios y archivos
# ─────────────────────────────────────────────────────────────────
step "Eliminando archivos de bellion..."

for bin in "$BIN_BELLION" "$BIN_REPAIR"; do
    if [[ -f "$bin" ]]; then
        rm -f "$bin"; ok "$bin eliminado"
    else
        ok "$bin ya no existía"
    fi
done

if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"; ok "$INSTALL_DIR eliminado (venv incluido)"
else
    ok "$INSTALL_DIR ya no existía"
fi

# ─────────────────────────────────────────────────────────────────
# PASO 5 — Verificación final
# ─────────────────────────────────────────────────────────────────
step "Verificación final..."

[[ ! -f "$BIN_BELLION" ]] && ok "Binario bellion eliminado"        || err "Binario sigue en $BIN_BELLION"
[[ ! -f "$BIN_REPAIR" ]]  && ok "Binario bellion-repair eliminado" || err "Binario sigue en $BIN_REPAIR"
[[ ! -d "$INSTALL_DIR" ]] && ok "Directorio eliminado"             || err "Directorio sigue en $INSTALL_DIR"
[[ ! -f "$CNF_BACKUP" ]]  && ok "Backup limpiado"                  || warn "Backup residual en $CNF_BACKUP"

if [[ -f "$CNF_ORIG" ]] && grep -q "bellion" "$CNF_ORIG" 2>/dev/null; then
    err "ADVERTENCIA: $CNF_ORIG aún tiene referencias a bellion"
else
    ok "command-not-found limpio"
fi

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  ✓ Desinstalación completa                           ║"
    echo "║    bash · zsh · fish restaurados                    ║"
    echo "║    .bashrc · .zshrc · dotfiles intactos             ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
else
    echo -e "${YELLOW}${BOLD}"
    printf "╔══════════════════════════════════════════════════════╗\n"
    printf "║  ⚠ Desinstalación con %-2d error(s)                    ║\n" "$ERRORS"
    printf "║    sudo apt install --reinstall command-not-found    ║\n"
    printf "╚══════════════════════════════════════════════════════╝\n"
    echo -e "${RESET}"
fi
