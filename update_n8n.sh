#!/bin/bash

# === Защита: запрещаем запуск через терминал ===
if [[ -t 1 ]]; then
  echo "🚫 Обновление можно запускать только через Telegram-бота, а не напрямую в терминале."
  exit 1
fi

# === Подключаем .env ===
set -a
source /opt/n8n-install/.env
set +a

# === Общие настройки ===
LOG="/opt/n8n-install/logs/update.log"
TG_URL="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"

function notify() {
  local text="$1"
  curl -s -X POST "$TG_URL" \
    -d chat_id="$TG_USER_ID" \
    -d parse_mode="Markdown" \
    -d text="$text"
}

# === Перехват ошибок ===
trap 'notify "❌ *ОШИБКА во время обновления!* См. лог в `/opt/n8n-install/logs/update.log`"' ERR

# === Начало ===
exec > >(tee -a "$LOG") 2>&1
echo -e "\n🟡 update_n8n.sh начался: $(date)"
notify "🛠 *Начинаю обновление n8n...*"

set -e
BASE_DIR="/opt/n8n-install"
cd "$BASE_DIR"

# === Шаг 1. Бэкап ===
echo "🔄 Шаг 1: создаю бэкап..."
notify "📦 *Шаг 1:* создаю бэкап..."
bash "$BASE_DIR/backup_n8n.sh"

# === Шаг 2. Проверка версий ===
echo "🔍 Шаг 2: проверяю версии n8n..."
CURRENT=$(docker exec n8n-app n8n --version)
LATEST=$(curl -s https://api.github.com/repos/n8n-io/n8n/releases/latest | grep '"tag_name":' | cut -d '"' -f 4)

if [ "$CURRENT" = "$LATEST" ]; then
  echo "✅ У вас уже последняя версия n8n: $CURRENT"
  notify "✅ *Уже последняя версия n8n:* $CURRENT"
  exit 0
fi

echo "🆕 Доступна новая версия: $LATEST (у вас: $CURRENT)"
notify "🔁 *Обновляю n8n с версии $CURRENT до $LATEST...*"

# === Шаг 3. Обновление контейнера n8n ===
echo "📦 Шаг 3: обновляю контейнер n8n..."
docker compose stop n8n
docker compose rm -f n8n
docker compose build --no-cache n8n
docker compose up -d n8n

# === Шаг 4. Проверка статуса ===
echo "🩺 Шаг 4: проверка статуса контейнера..."
sleep 5
docker ps | grep n8n

# === Шаг 5. Проверка версии ===
echo "🔎 Шаг 5: проверка обновлённой версии..."
NEW_VERSION=$(docker exec n8n-app n8n --version)
echo "🆗 Новая версия: $NEW_VERSION"

# === Шаг 6. Очистка системы ===
echo "🧹 Шаг 6: начинаю очистку системы..."
notify "🧹 *Шаг 6:* очищаю систему от мусора..."

apt-get clean
apt-get autoremove --purge -y
journalctl --vacuum-size=100M
journalctl --vacuum-time=7d
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/lib/docker/containers/ -type f -name "*-json.log" -exec truncate -s 0 {} \;
systemctl restart docker
docker image prune -f
docker builder prune -f
docker image prune -a -f
docker container prune -f
docker volume prune -f

docker system df
df -h | sed -n '1,5p'

# === Завершение ===
echo "✅ Обновление и очистка завершены! ($(date))"
notify "✅ *Обновление завершено!*\nТеперь установлена версия: *$NEW_VERSION*"
