#!/bin/bash
# code-scan.sh — ночное сканирование Downstream-репо (статистика активности)
#
# Обходит downstream-репозитории, собирает коммиты за последние 24ч,
# логирует активность.
#
# Использование:
#   code-scan.sh           # сканировать все downstream-репо
#   code-scan.sh --dry-run # показать что найдёт, не записывать
#
# Триггер: scheduler.sh dispatch (ежедневно)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# WP-273 0.29.4 R6.1 fix (issue #271): runtime-резолв вместо build-time {{WORKSPACE_DIR}} — как в strategist.sh.
WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
LOG_DIR="$HOME/logs/synchronizer"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/code-scan-$DATE.log"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [code-scan] $1" | tee -a "$LOG_FILE"
}

# === Обнаружение Downstream-репо ===

# Extra scan roots declared by the pilot in params.yaml (key: code_scan_paths,
# a list of directories or globs). The DS-*/ convention below only finds repos
# that sit next to the governance repo; a pilot whose working repos live
# elsewhere got "0 repos, 0 commits" with no hint that anything was missing.
# Silent no-op when python3/pyyaml or the key is absent — same soft-degrade
# contract as scripts/day-close.sh uses for linear_sync_path.
extra_scan_globs() {
    local params="$WORKSPACE/params.yaml"
    [ -f "$params" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -c '
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
data = yaml.safe_load(open(sys.argv[1])) or {}
for entry in (data.get("code_scan_paths") or []):
    if entry:
        print(entry)
' "$params" 2>/dev/null || true
}

discover_repos() {
    local repos=()

    # Governance-репо — исключаем из сканирования
    local exclude=(
        "${IWE_GOVERNANCE_REPO:-DS-strategy}"
    )

    for dir in "$WORKSPACE"/DS-*/; do
        [ -d "$dir/.git" ] || continue
        local name
        name=$(basename "$dir")
        local skip=false
        for ex in "${exclude[@]}"; do
            [ "$name" = "$ex" ] && skip=true && break
        done
        [ "$skip" = true ] && continue
        repos+=("$dir")
    done

    local glob expanded
    while IFS= read -r glob; do
        [ -n "$glob" ] || continue
        glob="${glob/#\~/$HOME}"
        # Unquoted on purpose: the pilot writes globs like ~/Code/cism/*.
        for expanded in $glob; do
            [ -d "$expanded/.git" ] || continue
            repos+=("${expanded%/}/")
        done
    done < <(extra_scan_globs)

    # bash 3.2 (stock /bin/bash on macOS) treats "${empty[@]}" as an unbound
    # variable under set -u, so an empty result aborted the whole scan instead
    # of reporting "nothing to scan".
    [ ${#repos[@]} -gt 0 ] || return 0
    printf '%s\n' "${repos[@]}" | sort -u
}

# === Основной цикл ===

scan_repos() {
    local total_repos=0
    local total_commits=0

    while IFS= read -r repo_dir; do
        repo_dir="${repo_dir%/}"
        local repo_name
        repo_name=$(basename "$repo_dir")

        local commits
        commits=$(git -C "$repo_dir" log --since="24 hours ago" --oneline --no-merges 2>/dev/null || true)

        if [ -z "$commits" ]; then
            log "SKIP: $repo_name — нет коммитов за 24ч"
            continue
        fi

        local count
        count=$(echo "$commits" | wc -l | tr -d ' ')
        log "FOUND: $repo_name — $count коммитов"

        total_repos=$((total_repos + 1))
        total_commits=$((total_commits + count))

    done < <(discover_repos)

    log "Итого: $total_repos репо, $total_commits коммитов"

    # Уведомление в Telegram
    if [ "$DRY_RUN" = false ] && [ "$total_repos" -gt 0 ]; then
        "$SCRIPT_DIR/notify.sh" synchronizer code-scan 2>/dev/null || true
    fi
}

log "=== Code Scan Started ==="
scan_repos
log "=== Code Scan Completed ==="
