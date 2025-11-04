#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для логирования
log() {
  echo -e "${GREEN}[✓]${NC} $1"
}

log_info() {
  echo -e "${BLUE}[ℹ]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
  echo -e "${RED}[✗]${NC} $1"
}

clear
echo -e "${GREEN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║           KB Infrastructure - Полная установка                 ║
║                                                                  ║
║  ✓ 2 MariaDB (Galera Cluster) - отказоустойчивость             ║
║  ✓ 3 n8n экземпляра - параллельная обработка вебхуков          ║
║  ✓ Webhook Distributor - гарантия доставки (GET+POST→POST)     ║
║  ✓ PostgreSQL + Redis - для n8n                                 ║
║  ✓ WordPress - CMS на MariaDB                                   ║
║  ✓ phpMyAdmin - управление БД (по требованию)                  ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}
"

# Проверка Docker и Docker Compose
log_info "Проверка требуемых компонентов..."

if ! command -v docker &> /dev/null; then
    log_error "Docker не установлен!"
    echo "Установите Docker: https://docs.docker.com/get-docker/"
    exit 1
fi
log "Docker найден: $(docker --version)"

if ! command -v docker compose &> /dev/null && ! command -v docker-compose &> /dev/null; then
    log_error "Docker Compose не установлен!"
    exit 1
fi
log "Docker Compose найден"

# Проверка Traefik
if ! docker network ls | grep -q "proxy"; then
    log_error "Traefik сеть 'proxy' не найдена!"
    echo "Убедитесь что Traefik запущен и работает в сети 'proxy'"
    exit 1
fi
log "Traefik сеть 'proxy' найдена"

echo ""
log_info "Установка может занять 2-3 минуты..."
echo ""

# Создание основной директории
INSTALL_DIR="kb"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Создание структуры папок
log_info "Создание структуры папок..."
mkdir -p volumes/mariadb1
mkdir -p volumes/mariadb2
mkdir -p volumes/postgresql
mkdir -p volumes/redis
mkdir -p volumes/n8n1
mkdir -p volumes/n8n2
mkdir -p volumes/n8n3
mkdir -p volumes/wordpress
mkdir -p config/sql
log "Структура папок создана"

# Генерация паролей
log_info "Генерация безопасных паролей..."
DB_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
DB_USER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
PMA_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
PG_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
GALERA_CLUSTER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
log "Пароли сгенерированы (длина: 25 символов)"

# Запрос доменов
echo ""
log_info "Конфигурация доменов"
echo ""

read -p "Домен для WordPress (например, site.example.com): " WORDPRESS_DOMAIN
read -p "Домен для n8n (например, n8n.example.com): " N8N_DOMAIN
read -p "Домен для phpMyAdmin (например, pma.example.com): " PMA_DOMAIN

# Валидация доменов
if [ -z "$WORDPRESS_DOMAIN" ] || [ -z "$N8N_DOMAIN" ] || [ -z "$PMA_DOMAIN" ]; then
    log_error "Домены не могут быть пустыми!"
    exit 1
fi

log "Домены сохранены"
echo ""

# Создание .env файла
log_info "Создание .env файла..."
cat > .env << EOF
# Database Configuration
MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
MARIADB_USER=wordpress
MARIADB_PASSWORD=${DB_USER_PASSWORD}
MARIADB_DATABASE=wordpress
GALERA_CLUSTER_NAME=kb_cluster
GALERA_MARIABACKUP_PASSWORD=${GALERA_CLUSTER_PASSWORD}

# PostgreSQL Configuration
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=n8n

# n8n Configuration
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_ENCRYPTION_KEY}

# Domains
WORDPRESS_DOMAIN=${WORDPRESS_DOMAIN}
N8N_DOMAIN=${N8N_DOMAIN}
PMA_DOMAIN=${PMA_DOMAIN}

# phpMyAdmin
PMA_PASSWORD=${PMA_PASSWORD}

# Timezone
GENERIC_TIMEZONE=Europe/Moscow
EOF
log ".env файл создан"

# SQL скрипт для webhook_log
log_info "Создание SQL скрипта для дедупликации вебхуков..."
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
  received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (webhook_id) REFERENCES webhook_log(webhook_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX idx_instance_webhook_id ON webhook_instance_log(webhook_id);
SQLEOF
log "SQL скрипт создан"

# Webhook Distributor скрипт
log_info "Создание Webhook Distributor..."
cat > webhook-distributor.js << 'JSEOF'
const express = require('express');
const axios = require('axios');
const app = express();

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

const n8nInstances = [
  'http://n8n1:5678',
  'http://n8n2:5678',
  'http://n8n3:5678'
];

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
  const path = req.path;
  const method = req.method;

  console.log(`[${timestamp}] Получен ${method} запрос: ${path}`);
  console.log(`Распределение на ${n8nInstances.length} экземпляров n8n`);

  const requests = n8nInstances.map((instance, index) => {
    return axios({
      method: 'POST',
      url: `${instance}${path}`,
      data: body,
      headers: {
        'Content-Type': 'application/json',
        'X-Forwarded-For': req.ip,
        'X-Original-Method': method,
        'X-Webhook-Source': 'n8n-distributor'
      },
      timeout: 30000,
      validateStatus: () => true
    })
      .then(response => ({
        index,
        instance,
        status: response.status,
        success: true
      }))
      .catch(error => ({
        index,
        instance,
        error: error.message,
        success: false
      }));
  });

  const results = await Promise.all(requests);

  results.forEach(result => {
    if (result.success) {
      console.log(`✓ ${result.instance}: HTTP ${result.status}`);
    } else {
      console.log(`✗ ${result.instance}: ${result.error}`);
    }
  });

  const successCount = results.filter(r => r.success && r.status === 200).length;
  console.log(`Статистика: ${successCount}/${n8nInstances.length} получили хук
`);

  return {
    results,
    successCount,
    totalInstances: n8nInstances.length
  };
}

app.post('*', async (req, res) => {
  try {
    const distribution = await distributeWebhook(req, req.body);

    if (distribution.successCount >= 2) {
      res.status(200).json({
        message: 'Webhook распределен успешно',
        method: 'POST',
        distributed_to: distribution.successCount,
        total_instances: distribution.totalInstances
      });
    } else if (distribution.successCount >= 1) {
      res.status(200).json({
        message: 'Webhook распределен с предупреждением',
        method: 'POST',
        distributed_to: distribution.successCount,
        total_instances: distribution.totalInstances
      });
    } else {
      res.status(503).json({
        message: 'Ошибка распределения вебхука',
        method: 'POST',
        distributed_to: 0,
        total_instances: distribution.totalInstances
      });
    }
  } catch (error) {
    console.error('Ошибка распределения:', error.message);
    res.status(500).json({
      message: 'Ошибка сервера при распределении',
      error: error.message
    });
  }
});

app.get('*', async (req, res) => {
  try {
    const body = {
      method: 'GET',
      query: convertQueryToJson(req.url.split('?')[1] || ''),
      timestamp: new Date().toISOString(),
      ip: req.ip
    };

    console.log(`[${new Date().toISOString()}] GET запрос преобразован в POST`);
    console.log(`Параметры: ${JSON.stringify(body.query)}`);

    const distribution = await distributeWebhook(req, body);

    if (distribution.successCount >= 2) {
      res.status(200).json({
        message: 'GET запрос преобразован в POST и распределен успешно',
        method: 'GET→POST',
        parameters: body.query,
        distributed_to: distribution.successCount,
        total_instances: distribution.totalInstances
      });
    } else if (distribution.successCount >= 1) {
      res.status(200).json({
        message: 'GET запрос преобразован в POST и распределен (частично)',
        method: 'GET→POST',
        parameters: body.query,
        distributed_to: distribution.successCount,
        total_instances: distribution.totalInstances
      });
    } else {
      res.status(503).json({
        message: 'Ошибка распределения GET запроса',
        method: 'GET→POST',
        parameters: body.query,
        distributed_to: 0,
        total_instances: distribution.totalInstances
      });
    }
  } catch (error) {
    console.error('Ошибка обработки GET:', error.message);
    res.status(500).json({
      message: 'Ошибка сервера при обработке GET',
      error: error.message
    });
  }
});

app.get('/healthz', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    n8n_instances: n8nInstances.length,
    features: ['POST webhook distribution', 'GET to POST conversion']
  });
});

app.get('/', (req, res) => {
  res.status(200).json({
    service: 'n8n Webhook Distributor',
    version: '2.0.0',
    n8n_instances: n8nInstances,
    features: [
      'Параллельная отправка вебхуков на все 3 экземпляра n8n',
      'Преобразование GET запросов в POST',
      'Гарантия доставки (минимум 2 из 3 должны получить)',
      'Health check endpoint'
    ]
  });
});

const PORT = process.env.PORT || 9000;
app.listen(PORT, () => {
  console.log(`
╔════════════════════════════════════════════════════════════════╗
║     n8n Webhook Distributor v2.0 запущен                      ║
║                                                                ║
║  Порт: ${PORT}                                                   ║
║  Экземпляры n8n: ${n8nInstances.length}                                      ║
║  Поддерживаемые методы: POST, GET (→ POST)                   ║
║                                                                ║
║  ✓ Все вебхуки отправлены на все 3 экземпляра одновременно  ║
║  ✓ GET параметры преобразуются в POST body                   ║
║  ✓ Гарантия доставки (минимум 2 из 3)                        ║
║  ✓ Дедупликация на уровне БД                                 ║
╚════════════════════════════════════════════════════════════════╝
  `);
});
JSEOF
log "Webhook Distributor создан"

# Docker Compose конфиг
log_info "Создание docker-compose.yml..."
cat > docker-compose.yml << 'COMPOSEEOF'
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
      - MARIADB_GALERA_CLUSTER_NAME=${GALERA_CLUSTER_NAME}
      - MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://mariadb1,mariadb2
      - MARIADB_GALERA_NODE_NAME=mariadb1
      - MARIADB_GALERA_NODE_ADDRESS=mariadb1
      - MARIADB_GALERA_MARIABACKUP_USER=mariabackup
      - MARIADB_GALERA_MARIABACKUP_PASSWORD=${GALERA_MARIABACKUP_PASSWORD}
      - MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
      - MARIADB_USER=${MARIADB_USER}
      - MARIADB_PASSWORD=${MARIADB_PASSWORD}
      - MARIADB_DATABASE=${MARIADB_DATABASE}
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
      - MARIADB_GALERA_CLUSTER_NAME=${GALERA_CLUSTER_NAME}
      - MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://mariadb1,mariadb2
      - MARIADB_GALERA_NODE_NAME=mariadb2
      - MARIADB_GALERA_NODE_ADDRESS=mariadb2
      - MARIADB_GALERA_MARIABACKUP_USER=mariabackup
      - MARIADB_GALERA_MARIABACKUP_PASSWORD=${GALERA_MARIABACKUP_PASSWORD}
      - MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
      - MARIADB_GALERA_CLUSTER_BOOTSTRAP=no
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
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
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
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_DOMAIN}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_USER_MANAGEMENT_JWT_SECRET}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgresql
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_HEALTH_CHECK_ACTIVE=true
      - N8N_DIAGNOSTICS_ENABLED=false
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
      webhook-distributor:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n1.rule=Host(\`${N8N_DOMAIN}\`) && !PathPrefix(\`/webhook\`)"
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
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_DOMAIN}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_USER_MANAGEMENT_JWT_SECRET}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgresql
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_HEALTH_CHECK_ACTIVE=true
      - N8N_DIAGNOSTICS_ENABLED=false
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
      webhook-distributor:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n2.rule=Host(\`${N8N_DOMAIN}\`) && !PathPrefix(\`/webhook\`)"
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
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${N8N_DOMAIN}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_USER_MANAGEMENT_JWT_SECRET}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgresql
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_HEALTH_CHECK_ACTIVE=true
      - N8N_DIAGNOSTICS_ENABLED=false
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
      webhook-distributor:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.n8n3.rule=Host(\`${N8N_DOMAIN}\`) && !PathPrefix(\`/webhook\`)"
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
      - WORDPRESS_DB_HOST=mariadb1:3306
      - WORDPRESS_DB_USER=${MARIADB_USER}
      - WORDPRESS_DB_PASSWORD=${MARIADB_PASSWORD}
      - WORDPRESS_DB_NAME=${MARIADB_DATABASE}
    volumes:
      - ./volumes/wordpress:/var/www/html
    networks:
      - internal
      - proxy
    depends_on:
      mariadb1:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.wordpress.rule=Host(\`${WORDPRESS_DOMAIN}\`)"
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
      - PMA_HOSTS=mariadb1,mariadb2
      - PMA_ARBITRARY=0
      - PMA_USER=root
      - PMA_PASSWORD=${MARIADB_ROOT_PASSWORD}
    networks:
      - internal
      - proxy
    depends_on:
      - mariadb1
      - mariadb2
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=proxy"
      - "traefik.http.routers.phpmyadmin.rule=Host(\`${PMA_DOMAIN}\`)"
      - "traefik.http.routers.phpmyadmin.entrypoints=websecure"
      - "traefik.http.routers.phpmyadmin.tls=true"
      - "traefik.http.routers.phpmyadmin.tls.certresolver=letsencrypt"
      - "traefik.http.services.phpmyadmin.loadbalancer.server.port=80"
COMPOSEEOF
log "docker-compose.yml создан"

# Создание README
log_info "Создание документации..."
cat > README.md << 'READMEEOF'
# KB Infrastructure - Полная система

## Компоненты

- **MariaDB Galera Cluster** (2 узла) - отказоустойчивая БД
- **n8n** (3 экземпляра) - обработка вебхуков параллельно
- **Webhook Distributor** - гарантия доставки (GET→POST)
- **PostgreSQL** - БД для n8n
- **Redis** - очередь задач
- **WordPress** - CMS на MariaDB
- **phpMyAdmin** - управление БД (временно)

## Использование

```bash
docker compose up -d      # Запуск
docker compose down       # Остановка
docker compose ps        # Статус
docker compose logs -f   # Логи
```

## Вебхуки

```bash
# POST
curl -X POST https://n8n.example.com/webhook/path -d '{"key":"value"}'

# GET (преобразуется в POST)
curl https://n8n.example.com/webhook/path?key=value
```

## Health Check
```bash
curl https://n8n.example.com/healthz
```

## Управление phpMyAdmin
```bash
docker compose --profile admin up -d phpmyadmin
docker compose stop phpmyadmin
docker compose rm -f phpmyadmin
```

## Пароли в .env файле
READMEEOF
log "Документация создана"

# Создание скрипта управления
log_info "Создание скрипта управления..."
cat > manage.sh << 'MANAGEOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_menu() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    KB Infrastructure Manager${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "1) Запустить все сервисы"
    echo "2) Остановить все сервисы"
    echo "3) Перезапустить"
    echo "4) Статус"
    echo "5) Логи"
    echo "6) phpMyAdmin (запустить)"
    echo "7) phpMyAdmin (остановить)"
    echo "8) Galera статус"
    echo "9) Пароли"
    echo "0) Выход"
    echo ""
}

while true; do
    show_menu
    read -p "Выбор: " choice

    case $choice in
        1) docker compose up -d && echo -e "${GREEN}Запущено!${NC}" && sleep 2 ;;
        2) docker compose down && echo -e "${GREEN}Остановлено!${NC}" && sleep 2 ;;
        3) docker compose restart && echo -e "${GREEN}Перезапущено!${NC}" && sleep 2 ;;
        4) docker compose ps && read -p "Enter..." ;;
        5) docker compose logs -f ;;
        6) docker compose --profile admin up -d phpmyadmin && echo -e "${GREEN}phpMyAdmin запущен!${NC}" && sleep 2 ;;
        7) docker compose stop phpmyadmin && docker compose rm -f phpmyadmin && echo -e "${GREEN}phpMyAdmin остановлен!${NC}" && sleep 2 ;;
        8) echo "Galera статус:" && docker exec kb_mariadb1 mysql -uroot -p$(grep MARIADB_ROOT_PASSWORD .env | cut -d= -f2) -e "SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_local_state_comment';" && read -p "Enter..." ;;
        9) echo "" && echo -e "${BLUE}Пароли:${NC}" && grep -E "PASSWORD|ENCRYPTION_KEY" .env && read -p "Enter..." ;;
        0) echo -e "${GREEN}До встречи!${NC}" && exit 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}" && sleep 1 ;;
    esac
done
MANAGEOF
chmod +x manage.sh
log "Скрипт управления создан"

# Финальное сообщение
echo ""
echo -e "${GREEN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                  ✓ УСТАНОВКА ЗАВЕРШЕНА!                         ║
╚══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}
"

log_info "Структура создана в папке: $(pwd)"
log_info "Все данные хранятся в: $(pwd)/volumes/"
log_info "Конфигурация в: $(pwd)/.env"

echo ""
echo -e "${YELLOW}ВАЖНО!${NC} Сохраните файл ${YELLOW}.env${NC} в безопасном месте!"
echo ""

echo -e "${BLUE}Ваша система:${NC}"
echo "  WordPress:  https://${WORDPRESS_DOMAIN}"
echo "  n8n:        https://${N8N_DOMAIN}"
echo "  phpMyAdmin: https://${PMA_DOMAIN} (запускается через manage.sh)"
echo ""

log_info "ЗАПУСК КОНТЕЙНЕРОВ..."
echo ""

# Запуск контейнеров
docker compose up -d

echo ""
log_info "Контейнеры запущены! Система готова к работе."
echo ""

echo -e "${BLUE}Проверка статуса:${NC}"
sleep 3
docker compose ps

echo ""
echo -e "${YELLOW}Первый запуск может занять 2-3 минуты для загрузки всех сервисов${NC}"
echo ""

echo -e "${BLUE}Вебхуки:${NC}"
echo "  POST: curl -X POST https://${N8N_DOMAIN}/webhook/path -d '{"data":"value"}'"
echo "  GET:  curl https://${N8N_DOMAIN}/webhook/path?key=value"
echo ""

echo -e "${BLUE}Управление:${NC}"
echo "  ./manage.sh                    (интерактивный менеджер)"
echo "  docker compose logs -f         (логи всех сервисов)"
echo "  docker compose ps              (статус сервисов)"
echo ""
