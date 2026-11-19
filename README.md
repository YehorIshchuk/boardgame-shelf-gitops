# boardgame-shelf-gitops

Репозиторій конфігурації (GitOps) для [BoardGame Shelf](https://github.com/YehorIshchuk/boardgame-shelf).
Тут описано **бажаний стан** кластера; Argo CD у кластері сам приводить його до цього стану. Ручних `helm upgrade` / `kubectl apply` для застосунку немає.

```
boardgame-shelf-gitops/
├── bootstrap/
│   ├── install.sh            одноразово: Argo CD + Secret БД + кореневий Application
│   ├── argocd-values.yaml    значення Helm-чарта argo/argo-cd
│   └── root-app.yaml         кореневий Application (App of Apps) — єдиний, що застосовується вручну
├── apps/
│   └── boardgame-shelf.yaml  дочірній Application: чарт + значення minikube, auto-sync
├── charts/
│   └── boardgame-shelf/      Helm-чарт із ЛР-4
├── environments/
│   └── minikube/values.yaml  значення для minikube (тег образу, репліки, конфіг)
└── scripts/demo.sh           демонстрація пп. 3–6
```

```
git push ──► GitHub ──► Argo CD (argocd) ──► кластер (boardgame)
                         root ──► apps/ ──► boardgame-shelf ──► charts/boardgame-shelf + environments/minikube/values.yaml
```

## Як це працює

1. `bootstrap/root-app.yaml` (Application `root`) стежить за каталогом `apps/` і створює з нього дочірні Application — патерн **App of Apps**.
2. `apps/boardgame-shelf.yaml` (Application `boardgame-shelf`) рендерить `charts/boardgame-shelf` зі значеннями `environments/minikube/values.yaml` і синхронізує результат у namespace `boardgame`.
3. `syncPolicy.automated` — Argo CD сам застосовує нові коміти; `prune: true` — видаляє з кластера те, що прибрали з Git; `selfHeal` — повертає ручні зміни в кластері.

Argo CD перечитує Git кожні 60 с (`timeout.reconciliation`); скрипт демонстрації додатково робить refresh, щоб не чекати.

## Секрети

Паролів у Git немає. Чарт отримує `database.auth.existingSecret: boardgame-db`, а сам Secret створює `bootstrap/install.sh` з випадковим паролем (`openssl rand`). Чарт не генерує пароль сам, бо Argo CD рендерить шаблони через `helm template`, де функція `lookup` не працює — згенерований пароль змінювався б при кожній синхронізації.
Для повністю декларативного варіанта Secret можна зберігати в Git зашифрованим (Sealed Secrets, SOPS, External Secrets Operator).

Репозиторій публічний, тому підключати його до Argo CD з токеном не потрібно. Для приватного:
`argocd repo add https://github.com/YehorIshchuk/boardgame-shelf-gitops.git --username <user> --password <PAT з правом read>`.

## Розгортання з нуля

```bash
minikube start
./bootstrap/install.sh          # Argo CD, Secret БД, кореневий Application
kubectl -n argocd port-forward svc/argocd-server 8080:80   # UI: http://localhost:8080
argocd login localhost:8080 --plaintext --grpc-web --username admin
argocd account update-password
```

## Як змінити застосунок

Будь-яка зміна — це коміт у цей репозиторій:

| Що змінити | Де |
|---|---|
| версію (тег образу) | `environments/minikube/values.yaml` → `image.tag` |
| кількість реплік | `backend.replicaCount`, `frontend.replicaCount` |
| назву клубу, строк видачі | `config.clubName`, `config.maxBorrowDays` |
| автосинхронізацію, selfHeal | `apps/boardgame-shelf.yaml` → `syncPolicy` |
| шаблони | `charts/boardgame-shelf/` |

```bash
vim environments/minikube/values.yaml
git commit -am "..." && git push
argocd app get boardgame-shelf --refresh      # не чекати 60 с
```

## Демонстрація (ЛР-5)

```bash
./scripts/demo.sh status       # Argo CD, дерево застосунку
./scripts/demo.sh release      # 1.1.0 -> 1.2.0 комітом
./scripts/demo.sh drift        # kubectl scale: OutOfSync без selfHeal, повернення з selfHeal
./scripts/demo.sh degraded     # неіснуючий тег: Synced + Degraded
./scripts/demo.sh revert       # git revert, git log, argocd app history
./scripts/demo.sh reset        # повернути 1.1.0 і selfHeal: false для повторного показу
```

Вивід кожної команди зберігається в `report/output/`.
