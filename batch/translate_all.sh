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
# Police de BD et qualité JPEG des pages traduites
FONT_PATH="${FONT_PATH:-$APP_DIR/fonts/comic shanns 2.ttf}"
SAVE_QUALITY="${SAVE_QUALITY:-85}"
# Nombre d'échecs avant d'abandonner un manga (.failed)
MAX_FAILURES="${MAX_FAILURES:-3}"

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

# record_failure <dossier destination> <libellé>
# Compte un échec ; au bout de MAX_FAILURES, écrit .failed pour abandonner ce manga.
record_failure() {
    local dest="$1" label="$2"
    status=1
    mkdir -p "$dest"
    local failures=$(( $(cat "$dest/.failures" 2>/dev/null || echo 0) + 1 ))
    echo "$failures" > "$dest/.failures"
    if [[ "$failures" -ge "$MAX_FAILURES" ]]; then
        echo "$(date) : abandon après $failures échecs, voir $LOG_FILE" > "$dest/.failed"
        echo "[$(date)] $label abandonné après $failures échecs (.failed écrit)" | tee -a "$LOG_FILE"
    fi
}

# translate <dossier source> <dossier destination> <fichier config> [mark_done]
# Avec mark_done=1, écrit <destination>/.done quand toutes les pages sont traduites
# sans erreur ; un dossier qui a déjà son .done n'est plus retraité. Après MAX_FAILURES
# échecs (erreur ou manga resté incomplet), écrit <destination>/.failed et abandonne ce
# manga : il ne bloque plus la file.
translate() {
    local src="$1" dest="$2" config="$3" mark_done="${4:-0}"
    local label="${src#$INPUT_DIR/}"
    # Le dossier a pu disparaître depuis le début du passage (manga importé entre-temps) :
    # sans ce test, le traducteur créerait un dossier de sortie vide
    if [[ ! -d "$src" ]]; then
        return
    fi
    if [[ "$mark_done" == 1 && ( -f "$dest/.done" || -f "$dest/.failed" ) ]]; then
        return
    fi
    worked=1
    echo "[$(date)] === $label ===" | tee -a "$LOG_FILE"

    local run_log
    run_log="$(mktemp)"
    local ok=1
    # --font-path doit venir après "local" : placé avant, il est écrasé par la valeur
    # par défaut de la sous-commande
    if ! venv/bin/python -m manga_translator local --font-path "$FONT_PATH" \
            -i "$src" -o "$dest" \
            --config-file "$config" --save-quality "$SAVE_QUALITY" 2>&1 | tee -a "$LOG_FILE" "$run_log"; then
        ok=0
    fi
    # Le traducteur sort avec le code 0 même quand une page échoue : on lit son journal
    if grep -q '^ERROR' "$run_log"; then
        ok=0
    fi

    if [[ "$ok" == 0 ]]; then
        rm -f "$run_log"
        echo "[$(date)] ERREUR sur $label (voir $LOG_FILE)" | tee -a "$LOG_FILE"
        [[ "$mark_done" == 1 ]] && record_failure "$dest" "$label"
        return
    fi

    if [[ "$mark_done" == 1 ]]; then
        # Pages illisibles (fichier abîmé dans le manga d'origine) : le traducteur les saute
        # avec un simple avertissement. On les copie telles quelles pour que le manga traduit
        # ait toutes ses pages, comme l'original.
        local page
        while IFS= read -r page; do
            [[ -f "$page" && ! -e "$dest/$(basename "$page")" ]] || continue
            cp "$page" "$dest/"
            echo "[$(date)] $label : page illisible $(basename "$page") copiée telle quelle" | tee -a "$LOG_FILE"
        done < <(sed -n 's/^WARNING: \[local\] Failed to open image: //p' "$run_log")

        local in_count out_count
        in_count="$(count_images "$src")"
        out_count="$(count_images "$dest")"
        if [[ "$in_count" -gt 0 && "$out_count" -ge "$in_count" ]]; then
            rm -f "$dest/.failures"
            touch "$dest/.done"
            echo "[$(date)] $label terminé ($out_count/$in_count pages), .done écrit" | tee -a "$LOG_FILE"
        else
            echo "[$(date)] $label incomplet ($out_count/$in_count pages)" | tee -a "$LOG_FILE"
            record_failure "$dest" "$label"
        fi
    fi
    rm -f "$run_log"
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
