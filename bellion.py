#!/usr/bin/env python3
"""
bellion v2.1 — TUI para encontrar e instalar paquetes de comandos no encontrados.
Busca en apt, snap y flatpak. Se activa automáticamente via command-not-found.
"""

import subprocess
import sys
import shutil
import os
import logging
import signal
from dataclasses import dataclass, field
from typing import Optional

logging.disable(logging.CRITICAL)

try:
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.containers import Horizontal, Vertical
    from textual.reactive import reactive
    from textual.widgets import Header, Footer, Input, DataTable, Static, LoadingIndicator, Label
    from textual import work
    from rich.text import Text
except ImportError:
    print("Error: dependencias no encontradas.", file=sys.stderr)
    print("Reinstala bellion: sudo bash install.sh", file=sys.stderr)
    sys.exit(1)


# ─────────────────────────── Helpers ────────────────────────────

def _run(cmd: list[str], timeout: int = 10) -> Optional[str]:
    try:
        return subprocess.check_output(
            cmd, stderr=subprocess.DEVNULL, text=True, timeout=timeout
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception):
        return None


def _run_lines(cmd: list[str], timeout: int = 10) -> list[str]:
    out = _run(cmd, timeout)
    return out.strip().splitlines() if out else []


# ─────────────────────────── Data ───────────────────────────────

@dataclass
class Package:
    name: str
    version: str
    description: str
    source: str        # "apt" | "snap" | "flatpak"
    provides: str
    installed: bool = False
    extra: dict = field(default_factory=dict)


# ─────────────────────────── Backends ───────────────────────────

def _apt_pkg_info(pkg_name: str) -> tuple[str, str]:
    version, desc = "—", "Sin descripción"
    out = _run(["apt-cache", "show", "--no-all-versions", pkg_name], timeout=6)
    if not out:
        return version, desc
    for line in out.splitlines():
        if line.startswith("Version:") and version == "—":
            version = line.split(":", 1)[1].strip()
        if (line.startswith("Description-es:") or line.startswith("Description:")) and desc == "Sin descripción":
            desc = line.split(":", 1)[1].strip()
    return version, desc


def _apt_is_installed(pkg_name: str) -> bool:
    out = _run(["dpkg-query", "-W", "-f=${Status}", pkg_name], timeout=4)
    return bool(out and "install ok installed" in out)


def search_apt(command: str) -> list[Package]:
    results: list[Package] = []
    seen: set[str] = set()

    def add_pkg(pkg_name: str, provides: str) -> None:
        if pkg_name in seen:
            return
        seen.add(pkg_name)
        ver, desc = _apt_pkg_info(pkg_name)
        results.append(Package(
            name=pkg_name, version=ver, description=desc,
            source="apt", provides=provides, installed=_apt_is_installed(pkg_name),
        ))

    if shutil.which("apt-file"):
        for prefix in (f"/usr/bin/{command}", f"/usr/sbin/{command}", f"/bin/{command}"):
            for line in _run_lines(["apt-file", "search", "--fixed-string", prefix], timeout=12):
                if ":" in line:
                    pkg = line.split(":", 1)[0].strip()
                    if pkg:
                        add_pkg(pkg, prefix)
            if results:
                break

    if not results and os.path.exists("/var/lib/command-not-found/commands.db"):
        out = _run(["python3", "-c",
            f"import sqlite3; db=sqlite3.connect('/var/lib/command-not-found/commands.db'); "
            f"[print(r[0]) for r in db.execute(\"SELECT package FROM commands WHERE command=?\", ('{command}',))]"
        ], timeout=5)
        if out:
            for pkg in out.strip().splitlines():
                if pkg:
                    add_pkg(pkg.strip(), command)

    if not results:
        for search_term in (f"^{command}$", command):
            lines = _run_lines(["apt-cache", "search", "--names-only", search_term], timeout=8)
            if not lines and search_term == f"^{command}$":
                lines = _run_lines(["apt-cache", "search", command], timeout=8)
            for line in lines[:8]:
                parts = line.split(" - ", 1)
                if len(parts) == 2:
                    add_pkg(parts[0].strip(), command)
            if results:
                break

    return results[:10]


def search_snap(command: str) -> list[Package]:
    if not shutil.which("snap") or _run(["snap", "version"], timeout=4) is None:
        return []
    results = []
    lines = _run_lines(["snap", "find", "--narrow", command], timeout=15) or \
            _run_lines(["snap", "find", command], timeout=15)
    for line in lines[1:8]:
        parts = line.split(None, 4)
        if len(parts) < 2:
            continue
        name = parts[0]
        version = parts[1] if len(parts) > 1 else "—"
        publisher = parts[2] if len(parts) > 2 else ""
        desc = parts[4].strip() if len(parts) > 4 else ""
        installed = bool(_run(["snap", "list", "--unicode=never", name], timeout=5) and name in (_run(["snap", "list", "--unicode=never", name], timeout=5) or ""))
        results.append(Package(
            name=name, version=version, description=desc,
            source="snap", provides=command, installed=installed,
            extra={"publisher": publisher},
        ))
    return results


def search_flatpak(command: str) -> list[Package]:
    if not shutil.which("flatpak"):
        return []
    results = []
    lines = _run_lines(["flatpak", "search", "--columns=name,description,application,version", command], timeout=15) or \
            _run_lines(["flatpak", "search", command], timeout=15)
    for line in lines[1:8]:
        parts = line.split("\t")
        name    = parts[0].strip() if len(parts) > 0 else ""
        desc    = parts[1].strip() if len(parts) > 1 else ""
        app_id  = parts[2].strip() if len(parts) > 2 else ""
        version = parts[3].strip() if len(parts) > 3 else "—"
        if not name:
            continue
        installed = bool(_run(["flatpak", "info", app_id], timeout=5)) if app_id else False
        results.append(Package(
            name=name, version=version, description=desc,
            source="flatpak", provides=command, installed=installed,
            extra={"app_id": app_id},
        ))
    return results


# ─────────────────────────── Instalación ────────────────────────

_TERMINALS = [
    ("gnome-terminal",  ["--wait", "--", "bash", "-c"]),
    ("konsole",         ["--noclose", "-e", "bash", "-c"]),
    ("xfce4-terminal",  ["--hold", "-e"]),
    ("mate-terminal",   ["-e"]),
    ("tilix",           ["-e", "bash", "-c"]),
    ("alacritty",       ["-e", "bash", "-c"]),
    ("kitty",           ["bash", "-c"]),
    ("wezterm",         ["start", "--", "bash", "-c"]),
    ("foot",            ["bash", "-c"]),
    ("lxterminal",      ["-e"]),
    ("xterm",           ["-hold", "-e", "bash", "-c"]),
    ("urxvt",           ["-hold", "-e", "bash", "-c"]),
    ("st",              ["-e", "bash", "-c"]),
]


def _find_terminal() -> Optional[tuple[str, list[str]]]:
    preferred = os.environ.get("TERMINAL", "")
    if preferred and shutil.which(preferred):
        for binary, args in _TERMINALS:
            if binary == preferred:
                return binary, args
    for binary, args in _TERMINALS:
        if shutil.which(binary):
            return binary, args
    return None


def install_package(pkg: Package) -> tuple[bool, str]:
    if pkg.source == "apt":
        install_cmd = f"sudo apt install -y {pkg.name}"
    elif pkg.source == "snap":
        install_cmd = f"sudo snap install {pkg.name}"
    elif pkg.source == "flatpak":
        app_id = pkg.extra.get("app_id") or pkg.name
        install_cmd = f"flatpak install -y {app_id}"
    else:
        return False, "Fuente desconocida"

    bar = "─" * 44
    inner = (
        f"echo '{bar}';"
        f"echo '  bellion — instalando {pkg.name} [{pkg.source}]';"
        f"echo '{bar}'; echo '';"
        f"{install_cmd}; EXIT=$?;"
        f"echo ''; echo '{bar}';"
        f"if [ $EXIT -eq 0 ]; then"
        f"  echo '  ✓ Instalación completada.';"
        f"else"
        f"  echo '  ✗ Error (código '$EXIT'). Corre manualmente:';"
        f"  echo '    {install_cmd}';"
        f"fi;"
        f"echo '{bar}'; echo '';"
        f"read -p '  Presiona Enter para cerrar...' _"
    )

    terminal = _find_terminal()
    if terminal is None:
        try:
            ret = subprocess.run(install_cmd, shell=True, timeout=300).returncode
            return (True, f"✓ {pkg.name} instalado") if ret == 0 else (False, f"✗ Error (código {ret})")
        except subprocess.TimeoutExpired:
            return False, "✗ Tiempo de espera agotado (300s)"
        except Exception as e:
            return False, f"✗ {e}"

    binary, args = terminal
    try:
        if binary in ("xfce4-terminal", "mate-terminal", "lxterminal"):
            cmd = [binary] + args + [f"bash -c {repr(inner)}"]
        else:
            cmd = [binary] + args + [inner]
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return True, f"↗ Instalando {pkg.name} — revisa la ventana abierta"
    except Exception as e:
        return False, f"✗ Error al abrir terminal: {e}"


# ─────────────────────────── TUI ────────────────────────────────

SOURCE_COLORS = {"apt": "#f5871f", "snap": "#82aaff", "flatpak": "#c792ea"}
SOURCE_LABELS = {"apt": " APT ", "snap": "SNAP", "flatpak": "FLATPAK"}
SOURCE_ICONS  = {"apt": "📦", "snap": "🔲", "flatpak": "📐"}


class StatusBar(Static):
    message: reactive[str] = reactive("")
    def render(self) -> str:
        return self.message
    def show(self, msg: str) -> None:
        self.message = msg


class DetailPanel(Static):
    pkg: reactive[Optional[Package]] = reactive(None)

    def render(self) -> Text:
        if self.pkg is None:
            t = Text()
            t.append("\n\n")
            t.append("  Selecciona un paquete\n", style="dim italic")
            t.append("  con ↑↓ para ver detalles\n", style="dim italic")
            t.append("\n")
            t.append("  Enter", style="bold #7aa2f7")
            t.append(" o ", style="dim")
            t.append("i", style="bold #7aa2f7")
            t.append(" para instalar\n", style="dim")
            t.append("  Ctrl+Q", style="bold #7aa2f7")
            t.append(" para salir\n", style="dim")
            return t

        p = self.pkg
        color = SOURCE_COLORS.get(p.source, "white")
        icon  = SOURCE_ICONS.get(p.source, "•")
        t = Text()

        # Header del paquete
        t.append(f"\n {icon} ", style="bold")
        t.append(f"{p.name}", style=f"bold white")
        if p.installed:
            t.append("  ✓ instalado", style="bold #a3e635")
        t.append("\n")
        t.append("─" * 28 + "\n", style="dim #3b4261")

        # Metadata
        label_style = "dim #a9b1d6"
        t.append("  fuente   ", style=label_style)
        t.append(f"{SOURCE_LABELS.get(p.source, p.source)}", style=f"bold {color}")
        t.append("\n")
        t.append("  versión  ", style=label_style)
        t.append(p.version, style="bold #7dcfff")
        t.append("\n")
        t.append("  provee   ", style=label_style)
        t.append(p.provides, style="#9ece6a")
        t.append("\n")

        if p.source == "flatpak" and p.extra.get("app_id"):
            t.append("  app id   ", style=label_style)
            t.append(p.extra["app_id"], style="#e0af68")
            t.append("\n")
        if p.source == "snap" and p.extra.get("publisher"):
            t.append("  autor    ", style=label_style)
            t.append(p.extra["publisher"], style="#e0af68")
            t.append("\n")

        t.append("─" * 28 + "\n", style="dim #3b4261")
        t.append("  descripción\n", style=label_style)
        t.append("  ")
        words = p.description.split()
        line_len = 0
        for word in words:
            if line_len + len(word) > 26:
                t.append("\n  ")
                line_len = 0
            t.append(word + " ", style="#c0caf5")
            line_len += len(word) + 1

        t.append("\n\n")
        if p.installed:
            t.append("  Ya está instalado\n", style="#a3e635 dim")
        else:
            t.append("  ╭─────────────────────╮\n", style="dim #3b4261")
            t.append("  │  Enter", style="#7aa2f7 bold")
            t.append(" · instalar  │\n", style="dim #3b4261")
            t.append("  ╰─────────────────────╯\n", style="dim #3b4261")
        return t


class BellionApp(App):
    CSS = """
    Screen {
        background: #1a1b26;
        color: #c0caf5;
    }

    Header {
        background: #16161e;
        color: #7aa2f7;
        text-style: bold;
        height: 1;
    }

    Footer {
        background: #16161e;
        color: #565f89;
        height: 1;
    }

    /* ── Barra de búsqueda ── */
    #search-bar {
        height: 3;
        padding: 0 1;
        background: #16161e;
        border-bottom: solid #292e42;
    }

    #search-label {
        width: auto;
        padding: 0 1;
        color: #7aa2f7;
        content-align: center middle;
        text-style: bold;
    }

    #search-input {
        background: #1f2335;
        border: tall #3b4261;
        color: #c0caf5;
        width: 1fr;
        padding: 0 1;
    }

    #search-input:focus {
        border: tall #7aa2f7;
    }

    /* ── Layout principal ── */
    #main-container {
        height: 1fr;
    }

    #table-panel {
        width: 2fr;
        border-right: solid #292e42;
    }

    /* ── Panel de detalle ── */
    #detail-panel {
        width: 32;
        padding: 0 1;
        background: #1f2335;
    }

    /* ── Tabla ── */
    DataTable {
        background: #1a1b26;
        height: 1fr;
    }

    DataTable > .datatable--header {
        background: #1e2030;
        color: #7aa2f7;
        text-style: bold;
    }

    DataTable > .datatable--header-hover {
        background: #292e42;
    }

    DataTable > .datatable--cursor {
        background: #2d3f76;
        color: #e0e4ff;
        text-style: bold;
    }

    DataTable > .datatable--hover {
        background: #1f2335;
    }

    /* ── Loading ── */
    #loading-container {
        height: 3;
        display: none;
        align: center middle;
        background: #1a1b26;
    }

    #loading-container.visible {
        display: block;
    }

    LoadingIndicator {
        color: #7aa2f7;
    }

    /* ── Status bar ── */
    #status-bar {
        height: 1;
        padding: 0 1;
        background: #16161e;
        color: #565f89;
        border-top: solid #292e42;
    }

    /* ── Empty state ── */
    #empty-state {
        height: 1fr;
        align: center middle;
        display: none;
    }

    #empty-state.visible {
        display: block;
    }

    #empty-label {
        color: #565f89;
        text-align: center;
    }
    """

    BINDINGS = [
        Binding("ctrl+q",  "quit",         "Salir",         show=True),
        Binding("enter",   "install",      "Instalar",      show=True),
        Binding("i",       "install",      "Instalar",      show=False),
        Binding("escape",  "clear_search", "Limpiar",       show=True),
        Binding("f5",      "refresh",      "Buscar de nuevo", show=True),
        Binding("tab",     "toggle_focus", "Cambiar foco",  show=True),
    ]

    def __init__(self, initial_command: str = "") -> None:
        super().__init__()
        self.initial_command = initial_command.strip()
        self.packages: list[Package] = []
        self.selected_pkg: Optional[Package] = None

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="search-bar"):
            yield Label("🔍", id="search-label")
            yield Input(
                placeholder="Escribe un comando para buscar… (ej: ffmpeg, gimp, node)",
                id="search-input",
                value=self.initial_command,
            )
        with Horizontal(id="main-container"):
            with Vertical(id="table-panel"):
                yield Vertical(LoadingIndicator(), id="loading-container")
                yield Vertical(
                    Static("Sin resultados", id="empty-label"),
                    id="empty-state",
                )
                yield DataTable(id="pkg-table", cursor_type="row", zebra_stripes=True)
            yield DetailPanel(id="detail-panel")
        yield StatusBar(id="status-bar")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#pkg-table", DataTable)
        table.add_columns("Fuente", "Paquete", "Versión", "Comando", "Descripción", "")
        table.cursor_type = "row"

        if self.initial_command:
            # Foco en tabla desde el inicio cuando hay comando → flechas funcionan de inmediato
            self.set_timer(0.05, lambda: self._trigger_search(self.initial_command))
        else:
            self.query_one("#search-input", Input).focus()

    def _populate_table(self, results: list[Package], command: str) -> None:
        self._set_loading(False)
        table = self.query_one("#pkg-table", DataTable)
        table.clear()

        if not results:
            self._show_empty(f"No se encontraron paquetes para '{command}'")
            self._status(f"Sin resultados para '{command}'")
            return

        self._hide_empty()
        for pkg in results:
            color = SOURCE_COLORS.get(pkg.source, "white")
            icon  = SOURCE_ICONS.get(pkg.source, "•")
            label = SOURCE_LABELS.get(pkg.source, pkg.source)
            desc  = (pkg.description[:50] + "…") if len(pkg.description) > 50 else pkg.description
            ver   = (pkg.version[:14] + "…") if len(pkg.version) > 14 else pkg.version
            status = Text("✓", style="bold #a3e635") if pkg.installed else Text("", style="dim")

            table.add_row(
                Text(f"{icon} {label}", style=f"bold {color}"),
                Text(pkg.name,      style="bold #e0e4ff"),
                Text(ver,           style="#7dcfff"),
                Text(pkg.provides,  style="#9ece6a"),
                Text(desc,          style="#a9b1d6"),
                status,
            )

        # Mover cursor a primera fila y dar foco a la tabla → flechas funcionan sin Tab
        table.move_cursor(row=0)
        table.focus()

        apt_n     = sum(1 for p in results if p.source == "apt")
        snap_n    = sum(1 for p in results if p.source == "snap")
        flatpak_n = sum(1 for p in results if p.source == "flatpak")
        parts = []
        if apt_n:     parts.append(f"apt:{apt_n}")
        if snap_n:    parts.append(f"snap:{snap_n}")
        if flatpak_n: parts.append(f"flatpak:{flatpak_n}")
        self._status(f"{len(results)} resultado(s) para '{command}'  ·  {' · '.join(parts)}")
        # Sync detalle con primera fila
        self._sync_detail(0)

    # ── Búsqueda ────────────────────────────────────────────────

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id != "search-input":
            return
        cmd = event.value.strip()
        if len(cmd) >= 2:
            self._trigger_search(cmd)
        elif not cmd:
            self._clear_table()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "search-input":
            self._trigger_search(event.value.strip())

    def _trigger_search(self, command: str) -> None:
        if not command:
            return
        self._clear_table()
        self._set_loading(True)
        self._hide_empty()
        self._status(f"Buscando '{command}' en apt · snap · flatpak…")
        self._search_worker(command)

    @work(exclusive=True, thread=True)
    def _search_worker(self, command: str) -> None:
        results: list[Package] = []
        errors: list[str] = []
        for name, fn in [("apt", search_apt), ("snap", search_snap), ("flatpak", search_flatpak)]:
            try:
                results.extend(fn(command))
            except Exception as e:
                errors.append(f"{name}: {e}")
        self.packages = results
        if errors:
            self.call_from_thread(self._status, f"Advertencias: {'; '.join(errors)}")
        self.call_from_thread(self._populate_table, results, command)

    # ── Selección ───────────────────────────────────────────────

    def _sync_detail(self, idx: int) -> None:
        if 0 <= idx < len(self.packages):
            self.selected_pkg = self.packages[idx]
            self.query_one("#detail-panel", DetailPanel).pkg = self.selected_pkg

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        self._sync_detail(event.cursor_row)

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        self._sync_detail(event.cursor_row)
        self.action_install()

    # ── Instalación ─────────────────────────────────────────────

    def action_install(self) -> None:
        if not self.selected_pkg:
            self._status("Selecciona un paquete primero (↑↓)")
            return
        if self.selected_pkg.installed:
            self._status(f"'{self.selected_pkg.name}' ya está instalado.")
            return
        self._status(f"Iniciando instalación de {self.selected_pkg.name}…")
        self._install_worker(self.selected_pkg)

    @work(exclusive=False, thread=True)
    def _install_worker(self, pkg: Package) -> None:
        ok, msg = install_package(pkg)
        if ok:
            pkg.installed = True
        self.call_from_thread(self._status, msg)

    # ── Acciones ────────────────────────────────────────────────

    def action_toggle_focus(self) -> None:
        focused = self.focused
        table = self.query_one("#pkg-table", DataTable)
        inp   = self.query_one("#search-input", Input)
        if focused is table:
            inp.focus()
        else:
            table.focus()

    def action_clear_search(self) -> None:
        self.query_one("#search-input", Input).value = ""
        self._clear_table()
        self.query_one("#search-input", Input).focus()

    def action_refresh(self) -> None:
        val = self.query_one("#search-input", Input).value.strip()
        if val:
            self._trigger_search(val)

    def _clear_table(self) -> None:
        self.query_one("#pkg-table", DataTable).clear()
        self.packages = []
        self.selected_pkg = None
        self.query_one("#detail-panel", DetailPanel).pkg = None
        self._hide_empty()

    def _set_loading(self, visible: bool) -> None:
        el = self.query_one("#loading-container")
        if visible:
            el.add_class("visible")
        else:
            el.remove_class("visible")

    def _show_empty(self, msg: str = "Sin resultados") -> None:
        el = self.query_one("#empty-state")
        self.query_one("#empty-label", Static).update(f"\n\n  {msg}\n")
        el.add_class("visible")

    def _hide_empty(self) -> None:
        self.query_one("#empty-state").remove_class("visible")

    def _status(self, msg: str) -> None:
        try:
            self.query_one("#status-bar", StatusBar).show(msg)
        except Exception:
            pass


# ─────────────────────────── Entry point ────────────────────────

def _parse_command() -> str:
    """
    Parsea el comando real ignorando '--' que bash inyecta al llamar al handler.
    bash llama: /usr/lib/command-not-found -- <comando>
    zsh llama:  /usr/lib/command-not-found <comando>
    """
    args = sys.argv[1:]
    # Filtrar '--' que bash pasa como separador
    args = [a for a in args if a != "--"]
    return args[0] if args else ""


def main() -> None:
    raw_args = sys.argv[1:]

    # Flags especiales (antes de filtrar '--')
    for arg in raw_args:
        if arg in ("-h", "--help"):
            print("Uso: bellion [comando]")
            print("  Abre la TUI de búsqueda de paquetes.")
            print("  Se activa automáticamente al escribir un comando inexistente.")
            sys.exit(0)
        if arg in ("-v", "--version"):
            print("bellion 2.1.0")
            sys.exit(0)

    command = _parse_command()

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        if command:
            print(f"{command}: comando no encontrado", file=sys.stderr)
        sys.exit(127)

    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))

    app = BellionApp(initial_command=command)
    try:
        app.run()
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as e:
        print(f"Error al iniciar bellion: {e}", file=sys.stderr)
        print("Reinstala con: sudo bash install.sh", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
