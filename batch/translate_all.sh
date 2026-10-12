#!/usr/bin/env bash
# Traduit tous les mangas de INPUT_DIR vers OUTPUT_DIR (même arborescence).
# Un dossier nommé par un code langue (FRA, ENG, ESP...) contient des dossiers de
# mangas à traduire vers cette langue ; les autres dossiers utilisent config.json.
# Les pages déjà traduites sont ignorées : on peut relancer le script sans risque.
# Dans les dossiers de langue, <OUTPUT_DIR>/<LANG>/<id>/.done est écrit une fois le manga
# entièrement traduit : c'est ce fichier qu'attend l'import d'OpenManga.
#
# Usage : batch/translate_all.sh [INPUT_DIR] [OUTPUT_DIR]
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT_DIR="${1:-${INPUT_DIR:-$HOME/manga/input}}"
OUTPUT_DIR="${2:-${OUTPUT_DIR:-$HOME/manga/output}}"
CONFIG_FILE="${CONFIG_FILE:-$APP_DIR/batch/config.json}"
LOG_DIR="${LOG_DIR:-$APP_DIR/batch/logs}"
LOCK_FILE="${LOCK_FILE:-/tmp/manga-translate.lock}"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S)_$$.log"

# Un seul lancement à la fois (utile avec cron)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Une traduction est déjà en cours, abandon." >&2
    exit 0
fi

# Caches (modèles Hugging Face, etc.) hors de la partition système
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$APP_DIR/../.cache}"
export HF_HOME="${HF_HOME:-$XDG_CACHE_HOME/huggingface}"

cd "$APP_DIR"
echo "[$(date)] Traduction de $INPUT_DIR -> $OUTPUT_DIR" | tee -a "$LOG_FILE"

shopt -s nullglob
status=0
worked=0

count_images() {
    find "$1" -type f 2>/dev/null | grep -Eic '\.(jpe?g|png|webp)$' || true
}

# translate <dossier source> <dossier destination> <fichier config> [mark_done]
# Avec mark_done=1, écrit <destination>/.done quand toutes les pages sont traduites
# sans erreur ; un dossier qui a déjà son .done n'est plus retraité.
translate() {
    local src="$1" dest="$2" config="$3" mark_done="${4:-0}"
    local label="${src#$INPUT_DIR/}"
    if [[ "$mark_done" == 1 && -f "$dest/.done" ]]; then
        return
    fi
    worked=1
    echo "[$(date)] === $label ===" | tee -a "$LOG_FILE"

    local run_log
    run_log="$(mktemp)"
    local ok=1
    if ! venv/bin/python -m manga_translator local \
            -i "$src" -o "$dest" \
            --config-file "$config" 2>&1 | tee -a "$LOG_FILE" "$run_log"; then
        ok=0
    fi
    # Le traducteur sort avec le code 0 même quand une page échoue : on lit son journal
    if grep -q '^ERROR' "$run_log"; then
        ok=0
    fi
    rm -f "$run_log"

    if [[ "$ok" == 0 ]]; then
        echo "[$(date)] ERREUR sur $label (voir $LOG_FILE)" | tee -a "$LOG_FILE"
        status=1
        return
    fi

    if [[ "$mark_done" == 1 ]]; then
        local in_count out_count
        in_count="$(count_images "$src")"
        out_count="$(count_images "$dest")"
        if [[ "$in_count" -gt 0 && "$out_count" -ge "$in_count" ]]; then
            touch "$dest/.done"
            echo "[$(date)] $label terminé ($out_count/$in_count pages), .done écrit" | tee -a "$LOG_FILE"
        else
            echo "[$(date)] $label incomplet ($out_count/$in_count pages)" | tee -a "$LOG_FILE"
            status=1
        fi
    fi
}

for entry in "$INPUT_DIR"/*/; do
    entry="${entry%/}"
    name="$(basename "$entry")"
    if [[ "$name" =~ ^[A-Z]{3}$ ]]; then
        # Dossier de langue (ex. FRA/<id manga>/) : traduit vers cette langue
        # Le traducteur reconnaît le format à l'extension : il faut un .json
        lang_dir="$(mktemp -d)"
        lang_config="$lang_dir/config.json"
        venv/bin/python -c 'import json,sys; c=json.load(open(sys.argv[1])); c.setdefault("translator",{})["target_lang"]=sys.argv[2]; json.dump(c,open(sys.argv[3],"w"))' \
            "$CONFIG_FILE" "$name" "$lang_config"
        mangas=("$entry"/*/)
        if [[ ${#mangas[@]} -eq 0 ]]; then
            continue
        fi
        for manga in "${mangas[@]}"; do
            manga="${manga%/}"
            translate "$manga" "$OUTPUT_DIR/$name/$(basename "$manga")" "$lang_config" 1
        done
        rm -rf "$lang_dir"
    else
        # Dossier de série classique : langue de config.json
        translate "$entry" "$OUTPUT_DIR/$name" "$CONFIG_FILE"
    fi
done

if [[ "$worked" == 0 ]]; then
    # Rien à traduire : pas de journal (le cron tourne souvent)
    rm -f "$LOG_FILE"
else
    echo "[$(date)] Terminé." | tee -a "$LOG_FILE"
fi
exit $status
