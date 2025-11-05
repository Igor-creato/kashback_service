#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${GREEN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║           KB Infrastructure - Полная установка                 ║
║                                                                  ║
║  ✓ 2 MariaDB (Galera Cluster)                                   ║
║  ✓ 3 n8n экземпляра                                             ║
║  ✓ Webhook Distributor (GET + POST)                             ║
║  ✓ PostgreSQL + Redis                                           ║
║  ✓ WordPress + phpMyAdmin                                       ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Проверка Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[✗]${NC} Docker не установлен!"
    exit 1
fi
echo -e "${GREEN}[✓]${NC} Docker найден"

if ! command -v docker compose &> /dev/null; then
    echo -e "${RED}[✗]${NC} Docker Compose не установлен!"
    exit 1
fi
echo -e "${GREEN}[✓]${NC} Docker Compose найден"

if ! docker network ls 2>/dev/null | grep -q "proxy"; then
    echo -e "${RED}[✗]${NC} Traefik сеть 'proxy' не найдена!"
    exit 1
fi
echo -e "${GREEN}[✓]${NC} Traefik найден"

echo ""

# Проверка, запущен ли скрипт через pipe (curl | bash)
if [ ! -t 0 ]; then
    # Скрипт запущен через pipe, завершаем с инструкциями
    echo -e "${RED}[✗]${NC} Скрипт запущен через pipe, интерактивный ввод невозможен!"
    echo ""
    echo -e "${YELLOW}Для установки используйте один из следующих способов:${NC}"
    echo ""
    echo -e "${YELLOW}1. Установка через переменные окружения:${NC}"
    echo "   ${BLUE}WORDPRESS_DOMAIN=site.example.com N8N_DOMAIN=n8n.example.com PMA_DOMAIN=pma.example.com curl -sSL https://raw.githubusercontent.com/Igor-creato/kashback_service/main/kb-install.sh | bash${NC}"
    echo ""
    echo -e "${YELLOW}2. Установка через аргументы:${NC}"
    echo "   ${BLUE}curl -sSL https://raw.githubusercontent.com/Igor-creato/kashback_service/main/kb-install.sh -o kb-install.sh && chmod +x kb-install.sh && ./kb-install.sh site.example.com n8n.example.com pma.example.com${NC}"
    echo ""
    echo -e "${YELLOW}3. Скачать и запустить:${NC}"
    echo "   ${BLUE}curl -sSL https://raw.githubusercontent.com/Igor-creato/kashback_service/main/kb-install.sh -o kb-install.sh && chmod +x kb-install.sh && WORDPRESS_DOMAIN=site.example.com N8N_DOMAIN=n8n.example.com PMA_DOMAIN=pma.example.com ./kb-install.sh${NC}"
    echo ""
    exit 1
fi

# Получение доменов из аргументов или интерактивно
if [ $# -eq 3 ]; then
    WORDPRESS_DOMAIN=$1
    N8N_DOMAIN=$2
    PMA_DOMAIN=$3
    echo -e "${GREEN}[✓]${NC} Домены получены из аргументов"
else
    # Проверяем переменные окружения
    if [ -z "$WORDPRESS_DOMAIN" ] || [ -z "$N8N_DOMAIN" ] || [ -z "$PMA_DOMAIN" ]; then
        echo -e "${BLUE}Введите домены:${NC}"
        echo ""

        # Функция для безопасного ввода домена
        input_domain() {
            local prompt="$1"
            local var_name="$2"
            local value=""
            
            while [ -z "$value" ]; do
                echo -n "$prompt"
                read -t 60 -r value 2>/dev/null
                
                if [ $? -eq 0 ] && [ -n "$value" ]; then
                    # Удаляем пробелы в начале и конце
                    value=$(echo "$value" | xargs)
                    # Проверяем что значение не пустое
                    if [ -z "$value" ]; then
                        echo -e "${RED}[✗]${NC} Значение не может быть пустым. Попробуйте снова."
                    fi
                else
                    echo -e "${RED}[✗]${NC} Ошибка ввода или таймаут. Попробуйте снова."
                    value=""
                fi
            done
            
            eval "$var_name=\"$value\""
        }

        input_domain "WordPress домен (например site.example.com): " "WORDPRESS_DOMAIN"
        input_domain "n8n домен (например n8n.example.com): " "N8N_DOMAIN"
        input_domain "phpMyAdmin домен (например pma.example.com): " "PMA_DOMAIN"
    else
        echo -e "${GREEN}[✓]${NC} Домены получены из переменных окружения"
    fi
fi

# Проверка что домены не пустые
if [ -z "$WORDPRESS_DOMAIN" ] || [ -z "$N8N_DOMAIN" ] || [ -z "$PMA_DOMAIN" ]; then
    echo -e "${RED}[✗]${NC} Ошибка: все домены должны быть заполнены!"
    exit 1
fi

# Дополнительная проверка формата доменов
for domain in "$WORDPRESS_DOMAIN" "$N8N_DOMAIN" "$PMA_DOMAIN"; do
    if ! echo "$domain" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]*\.[a-zA-Z]{2,}$'; then
        echo -e "${RED}[✗]${NC} Неверный формат домена: $domain"
        exit 1
    fi
done

echo -e "${GREEN}[✓]${NC} Домены сохранены"
echo ""

# Создание папки
echo -e "${BLUE}[ℹ]${NC} Создание структуры..."
mkdir -p kb
cd kb || exit 1

mkdir -p volumes/mariadb1 volumes/mariadb2 volumes/postgresql volumes/redis
mkdir -p volumes/n8n1 volumes/n8n2 volumes/n8n3 volumes/wordpress
mkdir -p config/sql logs/php

echo -e "${GREEN}[✓]${NC} Структура создана"

mkdir -p php-config
cat > php-config/wordpress.ini <<'INI'
; Увеличенные лимиты для WordPress
file_uploads = On
memory_limit = 512M
upload_max_filesize = 128M
post_max_size = 128M
max_execution_time = 600
max_input_time = 600
max_input_vars = 5000
max_file_uploads = 30

; Оптимизация производительности
opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 2
opcache.fast_shutdown = 1

; Безопасность
expose_php = Off
allow_url_fopen = Off
disable_functions = exec,passthru,shell_exec,system,proc_open,popen

; Логирование ошибок
log_errors = On
error_log = /var/log/php_errors.log
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT

; Настройки сессий
session.cookie_httponly = 1
session.use_strict_mode = 1
session.cookie_samesite = Strict

; Дополнительные параметры для WordPress
max_input_nesting_level = 64
pcntl_async_signals = Off
INI
echo -e "${GREEN}[✓]${NC} Улучшенная конфигурация PHP создана"


# Генерация паролей
echo -e "${BLUE}[ℹ]${NC} Генерация паролей..."
DB_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
DB_USER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
PG_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
GALERA_CLUSTER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
PMA_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
echo -e "${GREEN}[✓]${NC} Пароли сгенерированы"

# Создание .env файла
echo -e "${BLUE}[ℹ]${NC} Создание .env..."
cat > .env << EOF
MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
MARIADB_USER=wordpress
MARIADB_PASSWORD=${DB_USER_PASSWORD}
MARIADB_DATABASE=wordpress
GALERA_CLUSTER_NAME=kb_cluster
GALERA_MARIABACKUP_PASSWORD=${GALERA_CLUSTER_PASSWORD}

POSTGRES_USER=n8n
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=n8n

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_ENCRYPTION_KEY}

WORDPRESS_DOMAIN=${WORDPRESS_DOMAIN}
N8N_DOMAIN=${N8N_DOMAIN}
PMA_DOMAIN=${PMA_DOMAIN}

PMA_PASSWORD=${PMA_PASSWORD}
GENERIC_TIMEZONE=Europe/Moscow
EOF
echo -e "${GREEN}[✓]${NC} .env создан"

# SQL
echo -e "${BLUE}[ℹ]${NC} SQL скрипт..."
cat > config/sql/webhook-unique-constraint.sql << 'SQLEOF'
CREATE TABLE IF NOT EXISTS webhook_log (
  id INT AUTO_INCREMENT PRIMARY KEY,
  webhook_id VARCHAR(255) NOT NULL UNIQUE,
  n8n_instance VARCHAR(50),
  received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  processed BOOLEAN DEFAULT FALSE,
  result LONGTEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_webhook_processed ON webhook_log(processed);
CREATE INDEX idx_webhook_timestamp ON webhook_log(received_at);

CREATE TABLE IF NOT EXISTS webhook_instance_log (
  id INT AUTO_INCREMENT PRIMARY KEY,
  webhook_id VARCHAR(255) NOT NULL,
  instance_name VARCHAR(50) NOT NULL,
  status_code INT,
  received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_instance_webhook_id ON webhook_instance_log(webhook_id);
SQLEOF
echo -e "${GREEN}[✓]${NC} SQL создан"

# Webhook Distributor
echo -e "${BLUE}[ℹ]${NC} Webhook distributor..."
cat > webhook-distributor.js << 'JSEOF'
const express = require('express');
const axios = require('axios');
const app = express();

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

const n8nInstances = ['http://n8n1:5678', 'http://n8n2:5678', 'http://n8n3:5678'];

function convertQueryToJson(queryString) {
  const params = new URLSearchParams(queryString);
  const json = {};
  for (const [key, value] of params) {
    json[key] = isNaN(value) ? value : Number(value);
  }
  return json;
}

async function distributeWebhook(req, body) {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${req.method} ${req.path}`);

  const requests = n8nInstances.map((instance) => {
    return axios({
      method: 'POST',
      url: `${instance}${req.path}`,
      data: body,
      headers: {
        'Content-Type': 'application/json',
        'X-Original-Method': req.method,
        'X-Webhook-Source': 'distributor'
      },
      timeout: 30000,
      validateStatus: () => true
    })
      .then(response => ({ instance, status: response.status, success: true }))
      .catch(error => ({ instance, error: error.message, success: false }));
  });

  const results = await Promise.all(requests);
  const successCount = results.filter(r => r.success && r.status === 200).length;
  console.log(`✓ ${successCount}/${n8nInstances.length} получили
`);

  return { results, successCount, totalInstances: n8nInstances.length };
}

app.post('*', async (req, res) => {
  try {
    const distribution = await distributeWebhook(req, req.body);
    const status = distribution.successCount >= 2 ? 200 : (distribution.successCount >= 1 ? 200 : 503);
    res.status(status).json({
      message: 'Webhook распределен',
      distributed_to: distribution.successCount,
      total: distribution.totalInstances
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('*', async (req, res) => {
  try {
    const body = {
      method: 'GET',
      query: convertQueryToJson(req.url.split('?')[1] || ''),
      timestamp: new Date().toISOString()
    };

    const distribution = await distributeWebhook(req, body);
    const status = distribution.successCount >= 2 ? 200 : (distribution.successCount >= 1 ? 200 : 503);
    res.status(status).json({
      message: 'GET преобразован в POST',
      parameters: body.query,
      distributed_to: distribution.successCount
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'healthy', instances: n8nInstances.length });
});

const PORT = process.env.PORT || 9000;
app.listen(PORT, () => {
  console.log(`Webhook Distributor запущен на порту ${PORT}`);
});
JSEOF
echo -e "${GREEN}[✓]${NC} Webhook distributor создан"

# Docker Compose - БЕЗ СЛОЖНОГО ЭКРАНИРОВАНИЯ
echo -e "${BLUE}[ℹ]${NC} Docker compose..."
cat > docker-compose.yml << 'COMPOSEYML'
version: '3.8'

networks:
  proxy:
    external: true
  internal:
    driver: bridge

services:
  webhook-distributor:
    image: node:18-alpine
    container_name: kb_webhook_distributor
    restart: unless-stopped
    working_dir: /app
    volumes:
      - ./webhook-distributor.js:/app/webhook-distributor.js
    command: sh -c "npm install --no-save express axios && node webhook-distributor.js"
    networks:
      - internal
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.webhook.rule=Host(`${N8N_DOMAIN}`) && PathPrefix(`/webhook`)"
      - "traefik.http.routers.webhook.entrypoints=websecure"
      - "traefik.http.routers.webhook.tls=true"
      - "traefik.http.routers.webhook.tls.certresolver=letsencrypt"
      - "traefik.http.services.webhook.loadbalancer.server.port=9000"
    healthcheck:
      test: ['CMD-SHELL', 'wget --spider -q http://localhost:9000/healthz || exit 1']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  mariadb1:
    image: bitnami/mariadb-galera:latest
    container_name: kb_mariadb1
    restart: unless-stopped
    environment:
      MARIADB_GALERA_CLUSTER_NAME: kb_cluster
      MARIADB_GALERA_CLUSTER_ADDRESS: gcomm://mariadb1,mariadb2
      MARIADB_GALERA_NODE_NAME: mariadb1
      MARIADB_GALERA_NODE_ADDRESS: mariadb1
      MARIADB_GALERA_MARIABACKUP_USER: mariabackup
      MARIADB_GALERA_MARIABACKUP_PASSWORD: ${GALERA_MARIABACKUP_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_USER: ${MARIADB_USER}
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
      MARIADB_DATABASE: ${MARIADB_DATABASE}
    volumes:
      - ./volumes/mariadb1:/bitnami/mariadb
      - ./config/sql/webhook-unique-constraint.sql:/docker-entrypoint-initdb.d/webhook-unique-constraint.sql
    networks:
      - internal
    healthcheck:
      test: ['CMD', '/opt/bitnami/scripts/mariadb-galera/healthcheck.sh']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  mariadb2:
    image: bitnami/mariadb-galera:latest
    container_name: kb_mariadb2
    restart: unless-stopped
    environment:
      MARIADB_GALERA_CLUSTER_NAME: kb_cluster
      MARIADB_GALERA_CLUSTER_ADDRESS: gcomm://mariadb1,mariadb2
      MARIADB_GALERA_NODE_NAME: mariadb2
      MARIADB_GALERA_NODE_ADDRESS: mariadb2
      MARIADB_GALERA_MARIABACKUP_USER: mariabackup
      MARIADB_GALERA_MARIABACKUP_PASSWORD: ${GALERA_MARIABACKUP_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_GALERA_CLUSTER_BOOTSTRAP: 'no'
    volumes:
      - ./volumes/mariadb2:/bitnami/mariadb
    networks:
      - internal
    depends_on:
      mariadb1:
        condition: service_healthy
    healthcheck:
      test: ['CMD', '/opt/bitnami/scripts/mariadb-galera/healthcheck.sh']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  postgresql:
    image: postgres:16-alpine
    container_name: kb_postgresql
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ./volumes/postgresql:/var/lib/postgresql/data
    networks:
      - internal
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U ${POSTGRES_USER}']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  redis:
    image: redis:7-alpine
    container_name: kb_redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - ./volumes/redis:/data
    networks:
      - internal
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 30s
      timeout: 10s
      retries: 5

  n8n1:
    image: n8nio/n8n:latest
    container_name: kb_n8n1
    restart: unless-stopped
    environment:
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PORT: '5678'
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_USER_MANAGEMENT_JWT_SECRET: ${N8N_USER_MANAGEMENT_JWT_SECRET}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgresql
      DB_POSTGRESDB_PORT: '5432'
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: '6379'
      QUEUE_HEALTH_CHECK_ACTIVE: 'true'
      N8N_DIAGNOSTICS_ENABLED: 'false'
    volumes:
      - ./volumes/n8n1:/home/node/.n8n
    networks:
      - internal
      - proxy
    depends_on:
      postgresql:
        condition: service_healthy
      redis:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n1.rule=Host(`${N8N_DOMAIN}`) && !PathPrefix(`/webhook`)"
      - "traefik.http.routers.n8n1.entrypoints=websecure"
      - "traefik.http.routers.n8n1.tls=true"
      - "traefik.http.routers.n8n1.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n1.loadbalancer.server.port=5678"
    healthcheck:
      test: ['CMD-SHELL', 'wget --spider -q http://localhost:5678/healthz || exit 1']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  n8n2:
    image: n8nio/n8n:latest
    container_name: kb_n8n2
    restart: unless-stopped
    environment:
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PORT: '5678'
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_USER_MANAGEMENT_JWT_SECRET: ${N8N_USER_MANAGEMENT_JWT_SECRET}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgresql
      DB_POSTGRESDB_PORT: '5432'
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: '6379'
      QUEUE_HEALTH_CHECK_ACTIVE: 'true'
      N8N_DIAGNOSTICS_ENABLED: 'false'
    volumes:
      - ./volumes/n8n2:/home/node/.n8n
    networks:
      - internal
      - proxy
    depends_on:
      postgresql:
        condition: service_healthy
      redis:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n2.rule=Host(`${N8N_DOMAIN}`) && !PathPrefix(`/webhook`)"
      - "traefik.http.routers.n8n2.entrypoints=websecure"
      - "traefik.http.routers.n8n2.tls=true"
      - "traefik.http.routers.n8n2.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n2.loadbalancer.server.port=5678"
    healthcheck:
      test: ['CMD-SHELL', 'wget --spider -q http://localhost:5678/healthz || exit 1']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  n8n3:
    image: n8nio/n8n:latest
    container_name: kb_n8n3
    restart: unless-stopped
    environment:
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PORT: '5678'
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_USER_MANAGEMENT_JWT_SECRET: ${N8N_USER_MANAGEMENT_JWT_SECRET}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgresql
      DB_POSTGRESDB_PORT: '5432'
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: '6379'
      QUEUE_HEALTH_CHECK_ACTIVE: 'true'
      N8N_DIAGNOSTICS_ENABLED: 'false'
    volumes:
      - ./volumes/n8n3:/home/node/.n8n
    networks:
      - internal
      - proxy
    depends_on:
      postgresql:
        condition: service_healthy
      redis:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n3.rule=Host(`${N8N_DOMAIN}`) && !PathPrefix(`/webhook`)"
      - "traefik.http.routers.n8n3.entrypoints=websecure"
      - "traefik.http.routers.n8n3.tls=true"
      - "traefik.http.routers.n8n3.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n3.loadbalancer.server.port=5678"
    healthcheck:
      test: ['CMD-SHELL', 'wget --spider -q http://localhost:5678/healthz || exit 1']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  wordpress:
    image: wordpress:latest
    container_name: kb_wordpress
    restart: unless-stopped
    environment:
      WORDPRESS_DB_HOST: mariadb1:3306
      WORDPRESS_DB_USER: ${MARIADB_USER}
      WORDPRESS_DB_PASSWORD: ${MARIADB_PASSWORD}
      WORDPRESS_DB_NAME: ${MARIADB_DATABASE}
      # Дополнительные переменные для WordPress
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_MEMORY_LIMIT', '512M');
        define('WP_MAX_MEMORY_LIMIT', '512M');
        define('WP_DEBUG', false);
        define('WP_DEBUG_LOG', false);
        define('WP_DEBUG_DISPLAY', false);
        define('DISALLOW_FILE_EDIT', true);
        define('DISALLOW_FILE_MODS', true);
        define('WP_AUTO_UPDATE_CORE', false);
    volumes:
      - ./volumes/wordpress:/var/www/html
      - ./php-config/wordpress.ini:/usr/local/etc/php/conf.d/wordpress.ini:ro
      - ./logs/php:/var/log/php
    networks:
      - internal
      - proxy
    depends_on:
      mariadb1:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.wordpress.rule=Host(`${WORDPRESS_DOMAIN}`)"
      - "traefik.http.routers.wordpress.entrypoints=websecure"
      - "traefik.http.routers.wordpress.tls=true"
      - "traefik.http.routers.wordpress.tls.certresolver=letsencrypt"
      - "traefik.http.services.wordpress.loadbalancer.server.port=80"
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost/ || exit 1']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  phpmyadmin:
    image: phpmyadmin:latest
    container_name: kb_phpmyadmin
    restart: "no"
    profiles:
      - admin
    environment:
      PMA_HOSTS: mariadb1,mariadb2
      PMA_ARBITRARY: '0'
      PMA_USER: root
      PMA_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    networks:
      - internal
      - proxy
    depends_on:
      - mariadb1
      - mariadb2
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.phpmyadmin.rule=Host(`${PMA_DOMAIN}`)"
      - "traefik.http.routers.phpmyadmin.entrypoints=websecure"
      - "traefik.http.routers.phpmyadmin.tls=true"
      - "traefik.http.routers.phpmyadmin.tls.certresolver=letsencrypt"
      - "traefik.http.services.phpmyadmin.loadbalancer.server.port=80"
COMPOSEYML
echo -e "${GREEN}[✓]${NC} docker-compose.yml создан"

cat > README.md << 'READMEEOF'
# KB Infrastructure

Запуск: docker compose up -d
Остановка: docker compose down
Статус: docker compose ps
Логи: docker compose logs -f
READMEEOF

cat > manage.sh << 'MANAGEOF'
#!/bin/bash
while true; do
    clear
    echo "1) Запуск  2) Остановка  3) Логи  4) Статус  0) Выход"
    read -p "Выбор: " c
    case $c in
        1) docker compose up -d ;;
        2) docker compose down ;;
        3) docker compose logs -f ;;
        4) docker compose ps ;;
        0) exit 0 ;;
    esac
done
MANAGEOF
chmod +x manage.sh

echo -e "${GREEN}[✓]${NC} Все файлы созданы"

echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}✓ УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}Ваша система:${NC}"
echo "  WordPress:  https://${WORDPRESS_DOMAIN}"
echo "  n8n:        https://${N8N_DOMAIN}"
echo "  phpMyAdmin: https://${PMA_DOMAIN}"
echo ""

echo -e "${BLUE}Запуск контейнеров...${NC}"
docker compose up -d

sleep 3
echo ""
docker compose ps

echo ""
echo -e "${BLUE}Вебхуки:${NC}"
echo "  POST: curl -X POST https://${N8N_DOMAIN}/webhook/test -d '{"key":"value"}'"
echo "  GET: curl https://${N8N_DOMAIN}/webhook/test?key=value"
echo ""
echo -e "${BLUE}Управление: ./manage.sh${NC}"
echo ""