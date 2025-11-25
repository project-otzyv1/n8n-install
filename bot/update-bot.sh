#!/bin/bash
set -e

echo "📥 Загружаем свежую версию bot.js из GitHub..."
curl -s -o /opt/n8n-install/bot.js https://raw.githubusercontent.com/kalininlive/n8n-beget-install/main/bot.js

echo "🔄 Перезапускаем бота..."
docker restart n8n-bot

echo "✅ Бот обновлён и перезапущен."
