#!/bin/bash

# Завершать работу при ошибках в ключевых командах
set -e

echo "=== 1. Обновление системы и установка пакетов ==="
sudo apt update && sudo apt full-upgrade -y
# Добавлен dnsutils для работы команды dig
sudo apt install ufw fail2ban certbot curl git dnsutils -y

echo "=== 2. Установка Docker ==="
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
else
    echo "Docker уже установлен, пропускаем."
fi

echo "=== 3. Настройка Swap (2 ГБ) ==="
if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
    echo "Swap-файл уже существует."
fi

echo "=== 4. Оптимизация ядра (Swap, BBR, IP Forward) ==="
# Функция для настройки sysctl с защитой от дубликатов
sysctl_set() {
    local param="$1"
    local value="$2"
    if grep -q "^${param}" /etc/sysctl.conf; then
        sudo sed -i "s|^${param}.*|${param}=${value}|" /etc/sysctl.conf
    else
        echo "${param}=${value}" | sudo tee -a /etc/sysctl.conf
    fi
}

sysctl_set "vm.swappiness" "10"
sysctl_set "vm.vfs_cache_pressure" "50"
sysctl_set "net.core.default_qdisc" "fq"
sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
sysctl_set "net.ipv4.ip_forward" "1"

sudo sysctl -p

echo "=== 5. Отключение лишних служб для экономии RAM ==="
sudo systemctl stop snapd multipathd || true
sudo systemctl disable snapd multipathd || true

echo "=== 6. Ограничение размера логов systemd ==="
if grep -q "^SystemMaxUse=" /etc/systemd/journald.conf; then
    sudo sed -i 's/^SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
else
    echo "SystemMaxUse=200M" | sudo tee -a /etc/systemd/journald.conf
fi
sudo systemctl restart systemd-journald

echo "=== 7. Подготовка каталогов для Remnanode и Сертификатов ==="
mkdir -p /opt/remnanode/certs
chmod 755 /opt/remnanode/certs

read -p "Введите ваш домен (например, de-s0.amaterashimasu.xyz) или нажмите Enter: " DOMAIN

if [ -n "$DOMAIN" ]; then
    DOMAIN=$(echo "$DOMAIN" | tr -d '\r')
    CADDY_CERT_PATH="/var/lib/docker/volumes/amaterashimasu_caddy_data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN"

    echo "Проверка наличия сертификатов Caddy..."
    if [ -f "$CADDY_CERT_PATH/$DOMAIN.crt" ]; then
        cp -L "$CADDY_CERT_PATH/$DOMAIN.crt" /opt/remnanode/certs/fullchain.pem
        cp -L "$CADDY_CERT_PATH/$DOMAIN.key" /opt/remnanode/certs/privkey.pem
        chmod 644 /opt/remnanode/certs/*
        echo "✅ Сертификаты Caddy успешно скопированы в /opt/remnanode/certs/"
    else
        echo "⚠️ Сертификаты Caddy пока не найдены по пути: $CADDY_CERT_PATH"
        echo "Они будут скопированы автоматически службой Cron после запуска Caddy."
    fi

    # Автоматическая настройка Cron для ротации сертификатов каждые 12 часов
    CRON_CMD="0 */12 * * * cp -L $CADDY_CERT_PATH/$DOMAIN.crt /opt/remnanode/certs/fullchain.pem && cp -L $CADDY_CERT_PATH/$DOMAIN.key /opt/remnanode/certs/privkey.pem && chmod 644 /opt/remnanode/certs/*"
    ( sudo crontab -l 2>/dev/null | grep -v "$DOMAIN" ; echo "$CRON_CMD" ) | sudo crontab -
    echo "✅ Задача автообновления сертификатов добавлена в crontab."
fi

echo "=== 8. Настройка UFW (Firewall) ==="
# Базовые разрешенные порты
sudo ufw allow 22/tcp || true
sudo ufw allow 80/tcp || true
sudo ufw allow 443 || true

# Интерактивный запрос дополнительных портов
echo ""
echo "Введите дополнительные порты для открытия (например: 44310/tcp 44311/tcp)."
read -p "Порты через пробел (или Enter, чтобы пропустить): " CUSTOM_PORTS

if [ -n "$CUSTOM_PORTS" ]; then
    # Очищаем ввод от возможных скрытых символов (например, Windows-переводов строк \r)
    CUSTOM_PORTS=$(echo "$CUSTOM_PORTS" | tr -d '\r')
    
    for PORT in $CUSTOM_PORTS; do
        # Пропускаем, если пользователь случайно ввел стандартные порты
        if [[ "$PORT" =~ ^(22|80|443)(/.*)?$ ]]; then
            echo "ℹ️ Порт $PORT является базовым и уже открыт, пропускаем."
            continue
        fi
        
        # Пытаемся открыть порт. Если формат неверный, скрипт не упадет благодаря конструкции с if
        if sudo ufw allow "$PORT"; then
            echo "✅ Порт $PORT успешно открыт."
        else
            echo "⚠️ Ошибка: не удалось открыть порт '$PORT'. Проверьте формат (например: 44310/tcp)."
        fi
    done
fi

# Включение UFW
echo "Включаем брандмауэр..."
sudo ufw --force enable

echo "=== 9. Установка WARP Native ==="
bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh) || true

echo "=== 10. Подготовка каталога /opt/remnanode ==="
mkdir -p /opt/remnanode
cd /opt/remnanode

echo ""
echo "🎉 Первоначальная настройка завершена! 🎉"
echo "Ваш сервер готов к работе. Перейдите в рабочую директорию:"
echo "cd /opt/remnanode"
echo "Создайте файл конфигурации: nano docker-compose.yml"
echo "И запустите контейнеры: docker compose up -d"
