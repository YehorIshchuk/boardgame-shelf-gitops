#!/usr/bin/env bash
# Початкове розгортання (виконується один раз на чистому кластері):
#   1) Argo CD у namespace argocd (Helm-чарт argo/argo-cd з bootstrap/argocd-values.yaml);
#   2) Secret з паролем БД — створюється тут, а не зберігається в Git;
#   3) кореневий Application — єдиний об'єкт Argo CD, який застосовується вручну.
# Далі все, що опинилося в кластері, Argo CD бере з Git.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo ">>> Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f "$ROOT/bootstrap/argocd-values.yaml" --wait --timeout 10m
helm list -n argocd
kubectl -n argocd get pods

echo ">>> Secret БД (пароль генерується тут і в Git не потрапляє)"
kubectl create namespace boardgame --dry-run=client -o yaml | kubectl apply -f -
if kubectl -n boardgame get secret boardgame-db >/dev/null 2>&1; then
  echo "secret/boardgame-db уже існує — залишаю як є"
else
  kubectl -n boardgame create secret generic boardgame-db \
    --from-literal=POSTGRES_USER=shelf_app \
    --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
fi

echo ">>> Кореневий Application (App of Apps)"
kubectl apply -f "$ROOT/bootstrap/root-app.yaml"

cat <<EOF

Готово. Початковий пароль admin:
  $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

Веб-інтерфейс (в окремій вкладці Terminal):
  kubectl -n argocd port-forward svc/argocd-server 8080:80   ->  http://localhost:8080  (admin / пароль вище)

CLI:
  argocd login localhost:8080 --plaintext --grpc-web --username admin
  argocd account update-password
  kubectl -n argocd delete secret argocd-initial-admin-secret   # після зміни пароля
EOF
