#!/usr/bin/env bash
# Traduit tous les mangas de INPUT_DIR vers OUTPUT_DIR (même arborescence).
# Un dossier nommé par un code langue (FRA, ENG, ESP...) contient des dossiers de
# mangas à traduire vers cette langue ; les autres dossiers utilisent config.json.
# Les pages déjà traduites sont ignorées : on peut relancer le script sans risque.
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
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S).log"

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

# translate <dossier source> <dossier destination> <fichier config>
translate() {
    local src="$1" dest="$2" config="$3"
    echo "[$(date)] === ${src#$INPUT_DIR/} ===" | tee -a "$LOG_FILE"
    if ! venv/bin/python -m manga_translator local \
            -i "$src" -o "$dest" \
            --config-file "$config" 2>&1 | tee -a "$LOG_FILE"; then
        echo "[$(date)] ERREUR sur ${src#$INPUT_DIR/} (voir $LOG_FILE)" | tee -a "$LOG_FILE"
        status=1
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
        for manga in "$entry"/*/; do
            manga="${manga%/}"
            translate "$manga" "$OUTPUT_DIR/$name/$(basename "$manga")" "$lang_config"
        done
        rm -rf "$lang_dir"
    else
        # Dossier de série classique : langue de config.json
        translate "$entry" "$OUTPUT_DIR/$name" "$CONFIG_FILE"
    fi
done

echo "[$(date)] Terminé." | tee -a "$LOG_FILE"
exit $status
