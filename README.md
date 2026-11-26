# boardgame-shelf-gitops

Репозиторій конфігурації (GitOps) для [BoardGame Shelf](https://github.com/YehorIshchuk/boardgame-shelf) — варіант з **окремим репозиторієм**.
Тут описано **бажаний стан** кластера; Argo CD сам приводить кластер до нього. Ручних `helm upgrade` / `kubectl apply` для застосунку немає.

```
boardgame-shelf-gitops/
├── bootstrap/
│   ├── root.yaml                 кореневий Application — застосовується вручну один раз
│   └── install.sh                одноразово: Argo CD + Secret БД + root.yaml
├── argocd-apps/                  Application-и, якими керує root
│   └── boardgame-shelf.yaml      чарт + values-minikube.yaml, auto-sync, prune, selfHeal
├── charts/
│   └── boardgame-shelf/          чарт із ЛР-4 (Chart.yaml, values.yaml, templates/)
│       └── values-minikube.yaml  значення для minikube: тег образу, репліки, конфіг
└── scripts/demo.sh               демонстрація пп. 4–6
```

```
git push ──► GitHub ──► Argo CD (ns argocd) ──► кластер (ns boardgame)
               root ──► argocd-apps/ ──► boardgame-shelf ──► charts/boardgame-shelf + values-minikube.yaml
```

## Як це працює

1. `bootstrap/root.yaml` (Application `root`) стежить за каталогом `argocd-apps/` і створює з нього дочірні Application — патерн **App of Apps**. Новий застосунок чи компонент кластера додається одним файлом в `argocd-apps/`.
2. `argocd-apps/boardgame-shelf.yaml` (Application `boardgame-shelf`) рендерить `charts/boardgame-shelf` зі значеннями `values-minikube.yaml` (шлях відносно каталогу чарту) і синхронізує результат у namespace `boardgame`. Назва Application = назва Helm-релізу, тому об'єкти називаються `boardgame-shelf-*`, як у ЛР-4.
3. `syncPolicy.automated` — Argo CD сам застосовує нові коміти; `prune: true` — видаляє з кластера те, що прибрали з Git; `selfHeal` — повертає ручні зміни в кластері.
4. Argo CD лише рендерить шаблони (`helm template`), тому `helm list -n boardgame` порожній.

Argo CD перечитує Git кожні 60 с (`timeout.reconciliation`, задано в `install.sh`); `argocd app get … --refresh` або кнопка Refresh — одразу.

## Секрети

Паролів у Git немає. У `values-minikube.yaml` задано `database.auth.existingSecret: boardgame-db` — шаблон Secret чарта не рендериться, Deployment-и посилаються на Secret, створений вручну (`install.sh`, пароль з `openssl rand`). Argo CD не видаляє його навіть з `prune`, бо він не з Git. Повноцінні варіанти — Sealed Secrets, SOPS, External Secrets.

Репозиторій публічний, тому підключати його до Argo CD не потрібно. Для приватного:
`argocd repo add https://github.com/YehorIshchuk/boardgame-shelf-gitops.git --username YehorIshchuk --password <token з правом читання>`.

## Розгортання з нуля

```bash
minikube start
./bootstrap/install.sh                                        # Argo CD, Secret БД, root.yaml

kubectl -n argocd port-forward svc/argocd-server 8080:443     # окремий термінал; https://localhost:8080
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret

argocd app list
argocd app get boardgame-shelf
kubectl -n boardgame get pods
helm list -n boardgame                                        # порожньо

kubectl -n boardgame port-forward svc/boardgame-shelf-frontend 8081:80   # http://localhost:8081
curl localhost:8081/api/version
```

## Як змінити застосунок

Будь-яка зміна — коміт у цей репозиторій:

| Що змінити | Де |
|---|---|
| версію (тег образу) | `charts/boardgame-shelf/values-minikube.yaml` → `image.tag` |
| кількість реплік | `backend.replicaCount`, `frontend.replicaCount` |
| змінні оточення (назва клубу, строк видачі) | `config.clubName`, `config.maxBorrowDays` |
| автосинхронізацію, selfHeal | `argocd-apps/boardgame-shelf.yaml` → `syncPolicy` |
| шаблони | `charts/boardgame-shelf/templates/` |

```bash
vim charts/boardgame-shelf/values-minikube.yaml
git commit -am "..." && git push
argocd app get boardgame-shelf --refresh
```

## Демонстрація (ЛР-5)

```bash
./scripts/demo.sh status       # Argo CD, root → boardgame-shelf, helm list порожній
./scripts/demo.sh release      # 1.1.0 -> 1.2.0 комітом
./scripts/demo.sh drift        # kubectl scale: OutOfSync без selfHeal, повернення з selfHeal
./scripts/demo.sh degraded     # тег 9.9.9-does-not-exist: Synced + Degraded
./scripts/demo.sh revert       # git revert, git log, argocd app history
./scripts/demo.sh reset        # повернути 1.1.0 і selfHeal: false для повторного показу
```

Вивід кожної команди зберігається в `report/output/`.
