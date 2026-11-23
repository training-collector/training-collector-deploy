# Развёртывание Training Collector

Весь сервис работает на одном сервере в Docker Compose: PostgreSQL, бэкенд, два бота, кабинет тренера, админка, внешний nginx с HTTPS, certbot и ежедневная резервная копия базы. Сервер — бесплатная машина Oracle Cloud (Always Free, Ampere A1, arm64).

```
Интернет ──443──▶ nginx (proxy) ──▶ /api/v1/*, /admin/v1/*  ──▶ backend ──▶ PostgreSQL
                       │                 остальное           ──▶ frontend / admin-frontend
                       └─80─ проверки Let's Encrypt, переадресация на HTTPS
bot, auth-bot ──long polling──▶ Telegram;  ──http://backend:8080/internal/v1/*──▶ backend
```

Наружу открыты только порты 80 и 443 у `proxy` и SSH сервера. Бэкенд, база и служебные маршруты `/internal/v1/*` доступны только внутри сети Docker.

## Как выкатываются изменения

Каждый репозиторий сервиса содержит `.github/workflows/deploy.yml`:

1. На каждый push и pull request запускаются тесты (`./gradlew build` или `npm run build`).
2. После push в `main` образ собирается под arm64 на раннере GitHub и публикуется в `ghcr.io/training-collector/<репозиторий>` с тегами `latest` и хешем коммита.
3. Workflow подключается к серверу по SSH пользователем `deploy`. Его ключ может запускать только `server/deploy.sh`: скрипт скачивает новый образ и перезапускает один сервис. Образы закрытые: workflow передаёт серверу свой временный `GITHUB_TOKEN`, сервер входит с ним в реестр только на время скачивания и ничего не сохраняет. Токен перестаёт действовать, когда заканчивается задача Actions.

Push в этот репозиторий применяет конфигурацию: сервер обновляет свою копию репозитория и перезапускает изменившиеся сервисы.

Для выкатки в каждом репозитории (пяти сервисов и этом) нужны три секрета Actions: `DEPLOY_HOST` (IP сервера), `DEPLOY_SSH_KEY` (закрытый ключ из `oracle/.state/deploy_key`) и `DEPLOY_KNOWN_HOSTS` (вывод `ssh-keyscan <IP>`). Пока `DEPLOY_HOST` не задан, workflow собирает образ и пропускает выкатку.

Откат: в Actions откройте прогон нужного старого коммита и нажмите **Re-run all jobs**. Его образ снова станет `latest` и будет выкачен.

## Первый запуск

1. **Oracle Cloud.** Установите CLI (`brew install oci-cli`) и войдите через браузер:
   ```sh
   oci session authenticate --profile-name training-collector --region <домашний регион>
   ```
   Сессия действует час. Затем создайте ресурсы:
   ```sh
   ALERT_EMAIL=you@example.com oracle/provision.sh
   ```
   Скрипт создаёт отдельный compartment, сеть с открытыми портами 22, 80 и 443 и машину `VM.Standard.A1.Flex` (по умолчанию 2 OCPU, 12 ГБ памяти, диск 50 ГБ; размер меняют `OCPUS`, `MEMORY_GB`, `BOOT_GB`). Размеры выше лимитов Always Free скрипт откажется создавать, как и машину, которая вместе с уже существующими выйдет за лимит. Ещё он создаёт бюджет с письмом на `ALERT_EMAIL` при первом начислении. Повторный запуск ничего не дублирует. Если A1 сейчас нет в наличии ни в одной зоне доступности («Out of capacity»), запустите скрипт позже.
2. **DNS.** Создайте записи A на IP из `oracle/.state/ip` для домена кабинета, для `www` этого домена (переадресуется на домен без `www`) и для домена админки, например `trainer.example.com`, `www.trainer.example.com` и `admin.trainer.example.com`.
3. **Боты.** Заведите в @BotFather двух ботов для продакшена, отдельно от ботов для локальной разработки: на один токен может работать только один экземпляр.
4. **Секреты на сервере.** Пароли БД, ключи ботов и `APP_SECRET` генерируются на самом сервере и не покидают его:
   ```sh
   ssh ubuntu@<IP> 'cd /opt/training-collector && sudo -u deploy env SITE_DOMAIN=... ADMIN_DOMAIN=... ACME_EMAIL=... \
     ADMIN_LOGIN=... ADMIN_PASSWORD=... AUTH_BOT_TOKEN=... BOT_TOKEN=... server/setup-env.sh'
   ```
   Для пробного запуска добавьте `CERTBOT_STAGING=1`: сертификаты будут тестовыми, зато лимиты Let's Encrypt не тратятся.
5. **Запуск.** `ssh ubuntu@<IP> 'cd /opt/training-collector && sudo -u deploy docker compose up -d'`. Через минуту-две certbot выпустит сертификаты, и nginx переключится на HTTPS сам. До этого сайт отвечает «The certificate is being issued».
6. **Секреты GitHub** для выкатки: см. раздел выше.

## Обслуживание

- **Резервные копии:** `backups/training-ГГГГ-ММ-ДД.dump`, хранятся 14 дней (`BACKUP_KEEP_DAYS`). Это копия на том же сервере, поэтому периодически скачивайте её к себе: `scp ubuntu@<IP>:/opt/training-collector/backups/*.dump .`. Восстановление: `docker compose exec -T db pg_restore -U training_app -d training --clean < файл.dump`.
- **Журналы:** `docker compose logs -f backend` и так далее. Каждый сервис хранит до 50 МБ журнала.
- **Обновления ОС** ставятся сами (`unattended-upgrades`).
- **Сертификаты** продлеваются сами за 30 дней до окончания.
- **Сменить домен:** поправьте `.env` и удалите старый сертификат: `docker compose run --rm --entrypoint certbot certbot delete --cert-name site` (или `admin`).

## Локальная проверка всего набора

```sh
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

Репозитории сервисов должны лежать рядом с этим. Без настоящего домена certbot не выпустит сертификат, и nginx останется на HTTP с ответом 503.
