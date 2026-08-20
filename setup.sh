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

echo "=== 7. Интерактивный выпуск SSL-сертификата (Certbot) ==="
read -p "Введите ваш домен (например, lt.amaterashimasu.xyz) или нажмите Enter для пропуска: " DOMAIN

if [ -n "$DOMAIN" ]; then
    echo "Проверка IP-адреса домена..."
    # Получаем текущий публичный IPv4 вашего сервера
    SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org)
    
    # Получаем IP-адрес, на который указывает домен
    DOMAIN_IP=$(dig +short A "$DOMAIN" | tail -n1)

    echo "IP сервера: $SERVER_IP"
    echo "IP домена ($DOMAIN): ${DOMAIN_IP:-'Не найден / Не резолвится'}"

    if [ "$SERVER_IP" = "$DOMAIN_IP" ]; then
        echo "✅ IP-адреса совпадают! Запускаем выпуск SSL..."
        # Останавливаем веб-сервер, если вдруг он уже запущен и занимает 80 порт
        sudo ufw allow 80/tcp
        sudo certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || true
        
        mkdir -p /opt/remnanode/certs
        if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /opt/remnanode/certs/
            cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /opt/remnanode/certs/
            echo "✅ Сертификаты успешно скопированы в /opt/remnanode/certs/"
        else
            echo "⚠️ Ошибка: не удалось найти выпущенные сертификаты."
        fi
    else
        echo "❌ Ошибка: IP-адрес домена ($DOMAIN_IP) не совпадает с IP сервера ($SERVER_IP)."
        echo "Выпуск SSL пропущен. Убедитесь, что A-запись обновилась, и запустите Certbot вручную позже."
    fi
else
    echo "Выпуск SSL пропущен."
fi

echo "=== 8. Настройка UFW (Firewall) ==="
# Базовые разрешенные порты
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Интерактивный запрос дополнительных портов
echo ""
echo "Введите дополнительные порты для открытия (например: 44350/tcp 8080/udp)."
read -p "Порты через пробел (или Enter, чтобы пропустить): " CUSTOM_PORTS

if [ -n "$CUSTOM_PORTS" ]; then
    for PORT in $CUSTOM_PORTS; do
        sudo ufw allow $PORT
        echo "Порт $PORT открыт."
    done
fi

# Включение UFW (с флагом --force, чтобы не спрашивал подтверждения прерывания SSH)
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