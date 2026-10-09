#!/usr/bin/env bash
# Traduit tous les mangas de INPUT_DIR vers OUTPUT_DIR (même arborescence).
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
for series in "$INPUT_DIR"/*/; do
    series="${series%/}"
    name="$(basename "$series")"
    echo "[$(date)] === $name ===" | tee -a "$LOG_FILE"
    if ! venv/bin/python -m manga_translator local \
            -i "$series" -o "$OUTPUT_DIR/$name" \
            --config-file "$CONFIG_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        echo "[$(date)] ERREUR sur $name (voir $LOG_FILE)" | tee -a "$LOG_FILE"
        status=1
    fi
done

echo "[$(date)] Terminé." | tee -a "$LOG_FILE"
exit $status
