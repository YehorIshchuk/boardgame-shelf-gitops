#!/usr/bin/env bash
# Початкове розгортання на чистому кластері (виконується один раз):
#   1) Argo CD в namespace argocd — офіційний маніфест (як в інструкції до ЛР-5);
#   2) Secret з паролем БД — створюється тут, а не зберігається в Git;
#   3) кореневий Application — єдиний ручний kubectl apply.
# Далі все, що опиняється в кластері, Argo CD бере з Git.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo ">>> 1. Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# перечитувати Git кожні 60 с замість 180 с (вебхуків у локального кластера немає)
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"60s"}}'
# SSO (Dex) і сповіщення в лабораторній не потрібні — звільняємо ресурси minikube
kubectl -n argocd scale deployment argocd-dex-server argocd-notifications-controller --replicas=0
for d in argocd-server argocd-repo-server argocd-redis argocd-applicationset-controller; do
  kubectl -n argocd rollout status deployment/$d --timeout=600s
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
kubectl -n argocd rollout restart deployment/argocd-repo-server statefulset/argocd-application-controller >/dev/null
kubectl -n argocd get pods

echo ">>> 2. Secret БД (пароль генерується тут і в Git не потрапляє)"
kubectl create namespace boardgame --dry-run=client -o yaml | kubectl apply -f -
if kubectl -n boardgame get secret boardgame-db >/dev/null 2>&1; then
  echo "secret/boardgame-db уже існує — залишаю як є"
else
  kubectl -n boardgame create secret generic boardgame-db \
    --from-literal=POSTGRES_USER=shelf_app \
    --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
fi

echo ">>> 3. Кореневий Application (App of Apps) — єдиний ручний apply"
kubectl apply -f "$ROOT/bootstrap/root.yaml"

cat <<'EOF'

Готово. Далі:
  # окремий термінал (не закривати):
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  # інтерфейс: https://localhost:8080 (сертифікат самопідписаний — браузер попередить)

  argocd admin initial-password -n argocd
  argocd login localhost:8080 --username admin --insecure
  argocd account update-password
  kubectl -n argocd delete secret argocd-initial-admin-secret

  argocd app list
  argocd app get boardgame-shelf
EOF
