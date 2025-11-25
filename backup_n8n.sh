#!/bin/sh
exec > /opt/n8n-install/backups/debug.log 2>&1
echo "🟡 backup_n8n.sh начался: $(date)"
set -e
set -x

# === Конфигурация ===
BACKUP_DIR="/opt/n8n-install/backups"
mkdir -p "$BACKUP_DIR"
NOW=$(date +"%Y-%m-%d-%H-%M")
ARCHIVE_NAME="n8n-backup-$NOW.zip"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"
BASE_DIR="/opt/n8n-install"
ENV_FILE="$BASE_DIR/.env"
EXPORT_DIR="$BASE_DIR/export_temp"
EXPORT_CREDS="$BASE_DIR/n8n_credentials.json"

# Очистка перед запуском
rm -f "$BACKUP_DIR"/n8n-backup-*.zip
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# === Загрузка переменных окружения ===
. "$ENV_FILE"
BOT_TOKEN="$TG_BOT_TOKEN"
USER_ID="$TG_USER_ID"

# === Сообщение, уведомление в TG ===
send_telegram() {
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$USER_ID" \
    -d text="$1"
}

# === Экспорт Workflows (по отдельным файлам) ===
docker exec n8n-app n8n export:workflow --all --separate --output=/tmp/export_dir || true
docker cp n8n-app:/tmp/export_dir "$EXPORT_DIR"

WF_COUNT=$(ls -1 "$EXPORT_DIR/export_dir"/*.json 2>/dev/null | wc -l)
if [ "$WF_COUNT" -eq 0 ]; then
  echo "⚠️ Внимание: воркфлоу не найдены"
  send_telegram "⚠️ Внимание: в n8n нет ни одного workflow. Бэкап отменён."
  exit 1
fi
echo "✅ Экспортировано $WF_COUNT воркфлоу"

# === Экспорт Credentials ===
docker exec n8n-app n8n export:credentials --all --output=/tmp/creds.json || true

if docker cp n8n-app:/tmp/creds.json "$EXPORT_CREDS"; then
  echo "✅ credentials экспортированы"
else
  echo "⚠️ Внимание: credentials отсутствуют, создаю пустой JSON"
  echo '{}' > "$EXPORT_CREDS"
  send_telegram "⚠️ Внимание: в n8n нет ни одного credentials. Бэкап выполнен только для workflows."
fi

# === Создание архива (воркфлоу + credentials) ===
zip -j "$ARCHIVE_PATH" "$EXPORT_CREDS"
zip -j "$ARCHIVE_PATH" "$EXPORT_DIR/export_dir"/*.json

# === Отправка архива в Telegram — как РАНЬШЕ ===
curl -s -F "document=@$ARCHIVE_PATH" \
  "https://api.telegram.org/bot$BOT_TOKEN/sendDocument?chat_id=$USER_ID&caption=Backup%20n8n%20(%20$NOW%20)" \
  && echo "✅ Архив отправлен в Telegram" >> "$BACKUP_DIR/debug.log"

# === Временные файлы — очищаем, архив сохраняем до следующего запуска
rm -rf "$EXPORT_DIR" "$EXPORT_CREDS"
