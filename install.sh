#!/bin/bash
# Terminaly installer.
#   curl -fsSL https://raw.githubusercontent.com/drarekx/terminaly/main/install.sh | bash
# Options (pass after `bash -s --`):
#   --no-cli   don't link the `tly` command-line tool
set -euo pipefail

REPO="drarekx/terminaly"
URL="${TERMINALY_ZIP_URL:-https://github.com/$REPO/releases/latest/download/Terminaly.zip}"
INSTALL_CLI=1
for arg in "$@"; do
    [[ "$arg" == "--no-cli" ]] && INSTALL_CLI=0
done

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31mError:\033[0m %s\n" "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Terminaly solo funciona en macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "Terminaly necesita macOS 14 (Sonoma) o posterior. Tienes $(sw_vers -productVersion)."

bold "Descargando Terminaly…"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar "$URL" -o "$tmp/Terminaly.zip" || fail "No se pudo descargar $URL"
ditto -x -k "$tmp/Terminaly.zip" "$tmp"
[[ -d "$tmp/Terminaly.app" ]] || fail "El archivo descargado no contiene Terminaly.app"

# Close a running copy so it can be replaced. Sessions keep running in the tly host.
if pgrep -x Terminaly >/dev/null; then
    bold "Cerrando Terminaly (las sesiones siguen vivas)…"
    osascript -e 'quit app "Terminaly"' 2>/dev/null || true
    sleep 1
    pkill -x Terminaly 2>/dev/null || true
fi

dest="${TERMINALY_INSTALL_DIR:-/Applications}"
if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
fi
rm -rf "$dest/Terminaly.app"
mv "$tmp/Terminaly.app" "$dest/"
# The app is not notarized; skip the Gatekeeper prompt for this copy.
xattr -dr com.apple.quarantine "$dest/Terminaly.app" 2>/dev/null || true
bold "Instalado en $dest/Terminaly.app"

if (( INSTALL_CLI )); then
    tly="$dest/Terminaly.app/Contents/MacOS/tly"
    bindir=""
    for candidate in "${TERMINALY_BIN_DIR:-}" /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
        [[ -n "$candidate" && -d "$candidate" && -w "$candidate" ]] && { bindir="$candidate"; break; }
    done
    if [[ -z "$bindir" ]]; then
        bindir="$HOME/.local/bin"
        mkdir -p "$bindir"
    fi
    ln -sf "$tly" "$bindir/tly"
    bold "CLI: $bindir/tly"
    case ":$PATH:" in
        *":$bindir:"*) ;;
        *) echo "Añade $bindir a tu PATH para usar 'tly':  echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zshrc" ;;
    esac
fi

[[ -n "${TERMINALY_NO_OPEN:-}" ]] || open "$dest/Terminaly.app"
bold "¡Listo! Las actualizaciones llegan solas (Terminaly → Check for Updates…)."
