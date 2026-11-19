#!/usr/bin/env bash
# Демонстрація ЛР №5 (пп. 3–6). Сценарій сам робить commit і push у цей репозиторій,
# а Argo CD у кластері підхоплює зміни. Вивід кожної команди — у report/output/NN-*.txt.
#
#   ./scripts/demo.sh status            # стан Argo CD і застосунку
#   ./scripts/demo.sh release [1.2.0]   # п.5  новий тег образу в Git
#   ./scripts/demo.sh drift             # п.6a kubectl scale без selfHeal, потім з selfHeal
#   ./scripts/demo.sh degraded          # п.6b неіснуючий тег -> Synced + Degraded
#   ./scripts/demo.sh revert            # п.6c git revert -> назад у Healthy, історія
#   ./scripts/demo.sh reset             # повернути вихідний стан (1.1.0, selfHeal: false) для повтору
#   ./scripts/demo.sh all               # status release drift degraded revert
# Передумова: argocd login localhost:8080 --plaintext --grpc-web (див. README).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=boardgame-shelf
NS=boardgame
VALUES="$ROOT/environments/minikube/values.yaml"
CHILD="$ROOT/apps/boardgame-shelf.yaml"
OUT="$ROOT/report/output"
PAUSE="${PAUSE:-1}"
BAD_TAG="9.9.9-does-not-exist"
mkdir -p "$OUT"

run() {
  local file="$OUT/$1.txt"; shift
  printf '\n$ %s\n' "$*" | tee -a "$file"
  bash -c "$*" 2>&1 | tee -a "$file"
}
note() { local f="$OUT/$1.txt"; shift; printf '\n# %s\n' "$*" | tee -a "$f"; }
section() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
pause() { if [[ "$PAUSE" == "1" && -t 0 ]]; then read -rp $'\n[Enter] — далі (зробіть скриншот, якщо потрібно) '; fi; }

field() { kubectl -n argocd get application "$1" -o jsonpath="$2" 2>/dev/null; }
state() { echo "sync=$(field "$1" '{.status.sync.status}') health=$(field "$1" '{.status.health.status}') revision=$(field "$1" '{.status.sync.revision}' | cut -c1-7)"; }
# змусити Argo CD перечитати Git зараз, не чекаючи інтервалу (60 с)
refresh() { kubectl -n argocd annotate application "$1" argocd.argoproj.io/refresh=normal --overwrite >/dev/null; }

wait_for() { # <file> <опис> <секунд> <умова bash>
  local file="$1" what="$2" timeout="$3" cond="$4" t=0
  printf '\n# чекаємо: %s (до %s с)\n' "$what" "$timeout" | tee -a "$OUT/$file.txt"
  until bash -c "$cond" >/dev/null 2>&1; do
    sleep 5; t=$((t + 5))
    if (( t % 15 == 0 )); then echo "  ${t}s: $(state $APP)" | tee -a "$OUT/$file.txt"; fi
    if (( t >= timeout )); then echo "  тайм-аут" | tee -a "$OUT/$file.txt"; return 1; fi
  done
  echo "  готово за ${t}s: $(state $APP)" | tee -a "$OUT/$file.txt"
}

commit_push() { # <file> <повідомлення>
  run "$1" "cd '$ROOT' && git --no-pager diff --stat && git --no-pager diff"
  run "$1" "cd '$ROOT' && git commit -qam '$2' && git push -q && git --no-pager log --oneline -1"
}

current_tag() { awk '/^image:/{f=1} f && /tag:/{gsub(/"/,"",$2); print $2; exit}' "$VALUES"; }
set_tag() { perl -0pi -e "s/(image:\\n(?:[ ].*\\n)*?  tag: )\"[^\"]*\"/\${1}\"$1\"/" "$VALUES"; }
set_selfheal() { perl -pi -e "s/selfHeal: (true|false)/selfHeal: $1/" "$CHILD"; }

api_version() { # <file>
  run "$1" "kubectl -n $NS exec deploy/$APP-frontend -- wget -qO- http://127.0.0.1/api/version; echo"
}

# ------------------------------------------------------------------ 3-4
stage_status() {
  section "3-4. Argo CD і застосунок під його керуванням"
  rm -f "$OUT"/01-*.txt
  run 01-status "argocd version --short 2>/dev/null || argocd version"
  run 01-status "kubectl -n argocd get pods"
  run 01-status "argocd app list"
  run 01-status "argocd app get $APP --refresh | head -40"
  run 01-status "kubectl -n $NS get deploy,rs,pods,svc,pvc,cm,secret"
  api_version 01-status
  cat <<EOF

  Інтерфейс: kubectl -n argocd port-forward svc/argocd-server 8080:80  ->  http://localhost:8080
  Скриншоти: список застосунків (root і $APP), дерево $APP (Synced / Healthy).
EOF
  pause
}

# ------------------------------------------------------------------ 5
stage_release() {
  local new="${1:-1.2.0}" old rev
  old="$(current_tag)"
  section "5. Реліз через Git: тег образу $old -> $new"
  rm -f "$OUT"/02-*.txt
  api_version 02-release
  set_tag "$new"
  commit_push 02-release "release: boardgame-shelf $new"
  rev="$(git -C "$ROOT" rev-parse HEAD)"
  refresh $APP
  wait_for 02-release "Argo CD синхронізує коміт ${rev:0:7}" 300 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.status.sync.revision}')\" == $rev ]]"
  wait_for 02-release "нові поди готові (Healthy)" 300 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.status.health.status}')\" == Healthy ]] && kubectl -n $NS exec deploy/$APP-frontend -- wget -qO- http://127.0.0.1/api/version | grep -q '\"$new\"'"
  run 02-release "kubectl -n $NS get deploy -o wide | awk '{print \$1, \$2, \$7}'"
  api_version 02-release
  run 02-release "argocd app history $APP"
  echo "  Оновіть сторінку застосунку: у футері web v$new / API v$new і новий рядок статистики."
  pause
}

# ------------------------------------------------------------------ 6a
stage_drift() {
  local rev
  section "6a. Дрейф: ручна зміна в кластері без selfHeal"
  rm -f "$OUT"/03-*.txt
  set_selfheal false
  if ! git -C "$ROOT" diff --quiet; then
    commit_push 03-drift "argocd: selfHeal off"; refresh root; sleep 20
  fi
  run 03-drift "kubectl -n argocd get application $APP -o jsonpath='{.spec.syncPolicy.automated}'; echo"
  run 03-drift "kubectl -n $NS scale deploy/$APP-backend --replicas=5"
  refresh $APP
  wait_for 03-drift "Argo CD помітив розбіжність (OutOfSync)" 120 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.status.sync.status}')\" == OutOfSync ]]"
  run 03-drift "argocd app get $APP | sed -n '1,14p;/backend/p'"
  run 03-drift "argocd app diff $APP | head -20"
  echo "  чекаємо 30 с: без selfHeal Argo CD нічого не повертає"; sleep 30
  run 03-drift "kubectl -n $NS get deploy $APP-backend"
  pause

  section "6a. Вмикаємо selfHeal: true у Git (apps/boardgame-shelf.yaml)"
  set_selfheal true
  commit_push 03-drift "argocd: enable selfHeal for $APP"
  rev="$(git -C "$ROOT" rev-parse HEAD)"
  refresh root
  wait_for 03-drift "кореневий Application оновив дочірній (selfHeal=true)" 180 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')\" == true ]]"
  wait_for 03-drift "Argo CD повернув replicas=2 з Git" 180 \
    "[[ \"\$(kubectl -n $NS get deploy $APP-backend -o jsonpath='{.spec.replicas}')\" == 2 ]]"
  run 03-drift "kubectl -n $NS get deploy $APP-backend"
  note 03-drift "ще одна ручна зміна — тепер її повертають за секунди"
  run 03-drift "kubectl -n $NS scale deploy/$APP-backend --replicas=5; for i in 1 2 3 4 5 6; do sleep 5; echo \"+\$((i*5))s replicas=\$(kubectl -n $NS get deploy $APP-backend -o jsonpath='{.spec.replicas}')\"; done"
  run 03-drift "argocd app get $APP | sed -n '1,14p'"
  pause
}

# ------------------------------------------------------------------ 6b
stage_degraded() {
  local rev
  section "6b. Неіснуючий тег образу в Git -> Synced, але Degraded"
  rm -f "$OUT"/04-*.txt
  set_tag "$BAD_TAG"
  commit_push 04-degraded "release: boardgame-shelf $BAD_TAG (broken)"
  rev="$(git -C "$ROOT" rev-parse HEAD)"
  refresh $APP
  wait_for 04-degraded "Argo CD застосував коміт ${rev:0:7} (Synced)" 300 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.status.sync.revision}')\" == $rev ]]"
  wait_for 04-degraded "health=Degraded (progressDeadlineSeconds: 120)" 360 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.status.health.status}')\" == Degraded ]]"
  run 04-degraded "argocd app get $APP | sed -n '1,30p'"
  run 04-degraded "kubectl -n $NS get pods"
  note 04-degraded "старі поди продовжують обслуговувати запити (maxUnavailable: 0)"
  api_version 04-degraded
  pause
}

# ------------------------------------------------------------------ 6c
stage_revert() {
  local rev
  section "6c. Відкат через git revert"
  rm -f "$OUT"/05-*.txt
  run 05-revert "cd '$ROOT' && git revert --no-edit HEAD && git push -q && git --no-pager log --oneline -1"
  rev="$(git -C "$ROOT" rev-parse HEAD)"
  refresh $APP
  wait_for 05-revert "Argo CD синхронізує revert ${rev:0:7}" 300 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.status.sync.revision}')\" == $rev ]]"
  wait_for 05-revert "застосунок знову Healthy" 300 \
    "[[ \"\$(kubectl -n argocd get application $APP -o jsonpath='{.status.health.status}')\" == Healthy ]]"
  run 05-revert "cd '$ROOT' && git --no-pager log --oneline -8"
  run 05-revert "argocd app history $APP"
  run 05-revert "argocd app get $APP | sed -n '1,14p'"
  api_version 05-revert
  pause
}

# ------------------------------------------------------------------ reset
stage_reset() {
  section "Повернення вихідного стану для повторної демонстрації"
  set_tag "1.1.0"; set_selfheal false
  if git -C "$ROOT" diff --quiet; then echo "уже у вихідному стані"; return; fi
  commit_push 00-reset "demo: reset to 1.1.0, selfHeal off"
  refresh root; refresh $APP
}

case "${1:-all}" in
  status)   stage_status ;;
  release)  stage_release "${2:-1.2.0}" ;;
  drift)    stage_drift ;;
  degraded) stage_degraded ;;
  revert)   stage_revert ;;
  reset)    stage_reset ;;
  all)      stage_status; stage_release 1.2.0; stage_drift; stage_degraded; stage_revert ;;
  *) echo "usage: $0 [status|release [tag]|drift|degraded|revert|reset|all]" >&2; exit 1 ;;
esac
section "Готово. Вивід: report/output/"
ls -1 "$OUT"
