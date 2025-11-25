#!/bin/bash
set -euo pipefail

### Проверка прав
if (( EUID != 0 )); then
  echo "❗ Скрипт должен быть запущен от root: sudo bash <(curl ...)"
  exit 1
fi

clear
echo "🌐 Автоматическая установка n8n с GitHub"
echo "----------------------------------------"

### 1. Ввод переменных (только нужное)
read -p "🌐 Введите домен для n8n (например: n8n.example.com): " DOMAIN
read -p "📧 Введите email для SSL-сертификата Let's Encrypt: " EMAIL
read -p "🔐 Введите пароль для базы данных Postgres: " POSTGRES_PASSWORD
read -p "🤖 Введите Telegram Bot Token: " TG_BOT_TOKEN
read -p "👤 Введите Telegram User ID (для уведомлений): " TG_USER_ID
read -p "🗝️  Введите ключ шифрования для n8n (Enter для генерации): " N8N_ENCRYPTION_KEY

if [ -z "${N8N_ENCRYPTION_KEY}" ]; then
  N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"
  echo "✅ Сгенерирован ключ шифрования: ${N8N_ENCRYPTION_KEY}"
fi

### 2. Установка Docker и Compose (минимум действий)
echo "📦 Проверка Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

if ! command -v docker compose &>/dev/null; then
  curl -sSL https://github.com/docker/compose/releases/download/v2.23.3/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose || true
fi

### 3. Клонирование проекта с GitHub
echo "📥 Клонируем проект с GitHub..."
rm -rf /opt/n8n-install
git clone https://github.com/kalininlive/n8n-beget-install.git /opt/n8n-install
cd /opt/n8n-install

### 4. Генерация .env файлов (без Basic Auth — n8n сам спросит при первом запуске)
cat > ".env" <<EOF
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_EXPRESS_TRUST_PROXY=true
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_USER_ID=${TG_USER_ID}
EOF

# .env бота (как у тебя)
mkdir -p bot
cat > "bot/.env" <<EOF
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_USER_ID=${TG_USER_ID}
EOF

chmod 600 .env bot/.env

### 4.1 Создание нужных директорий и логов
mkdir -p logs backups
touch logs/backup.log
chown -R 1000:1000 logs backups
chmod -R 755 logs backups

### 4.2 Подготовка ACME-хранилища Traefik (права 600 обязательны)
docker run --rm -v traefik_letsencrypt:/letsencrypt alpine \
  sh -lc 'mkdir -p /letsencrypt && touch /letsencrypt/acme.json && chmod 600 /letsencrypt/acme.json'

### 5. Сборка кастомного образа n8n
docker build -f Dockerfile.n8n -t n8n-custom:latest .

### 6. Запуск docker compose (включая Telegram-бота, traefik, postgres, redis, n8n)
docker compose up -d

### 6.1 Триггерим первый HTTPS-запрос, чтобы Traefik запросил сертификат
sleep 5
curl -skI "https://${DOMAIN}" >/dev/null || true

### 6.2 Ожидаем выпуск сертификата (проверяем логи Traefik до 90 сек)
echo "⌛ Ждём выпуск сертификата Let’s Encrypt (до 90 сек)..."
DEADLINE=$(( $(date +%s) + 90 ))
CERT_OK=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if docker logs n8n-traefik 2>&1 | grep -Eiq 'obtained|certificate.+(added|renewed|generated)'; then
    CERT_OK=1
    break
  fi
  sleep 3
done

### 6.3 Финальная проверка HTTPS/issuer
HTTP_REDIRECT="$(curl -sI "http://${DOMAIN}" | tr -d '\r')"
ISSUER="$(openssl s_client -connect "${DOMAIN}:443" -servername "${DOMAIN}" -showcerts </dev/null 2>/dev/null | openssl x509 -noout -issuer || true)"

if echo "$HTTP_REDIRECT" | grep -qE '^HTTP/.* 308|^Location: https://'; then
  echo "✅ HTTP → HTTPS редирект работает"
else
  echo "⚠️  Внимание: HTTP может не редиректить на HTTPS — проверь traefik-лейблы"
fi

if echo "$ISSUER" | grep -qi "Let's Encrypt"; then
  echo "✅ Сертификат: Let’s Encrypt подключён"
else
  if [ "$CERT_OK" -eq 1 ]; then
    echo "⚠️  Сертификат выпущен, но issuer не распознан. Текущее значение: ${ISSUER}"
  else
    echo "⚠️  Не дождались явного сообщения о выпуске сертификата. Текущее значение issuer: ${ISSUER}"
  fi
fi

### 7. Настройка cron
echo "🔧 Устанавливаем cron-задачу на 02:00 каждый день"
chmod +x /opt/n8n-install/backup_n8n.sh

# безопасное добавление задания при set -e / pipefail
( crontab -l 2>/dev/null || true; \
  echo "0 2 * * * /bin/bash /opt/n8n-install/backup_n8n.sh >> /opt/n8n-install/logs/backup.log 2>&1" \
) | crontab -

### 8. Уведомление в Telegram
curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TG_USER_ID}" \
  -d text="✅ Установка n8n завершена. Домен: https://${DOMAIN}" >/dev/null 2>&1 || true

### 9. Финальный вывод
echo "📦 Активные контейнеры:"
docker ps --format "table {{.Names}}\t{{.Status}}"

echo
echo "🎉 Готово! Открой: https://${DOMAIN}"
echo "ℹ️  Логи Traefik: docker logs -f n8n-traefik"
