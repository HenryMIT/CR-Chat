# Imagen única de datos/: API REST (Apache + mod_php) y servidor WebSocket (Workerman,
# servicio `ws`, mismo build con `command: php ws/server.php start`).

# --- Swagger UI estático (versión fijada, sin CDN en tiempo de ejecución) -------------
FROM node:24-alpine AS swagger
ARG SWAGGER_UI_VERSION=5.34.1
WORKDIR /tmp/swagger
RUN npm pack "swagger-ui-dist@${SWAGGER_UI_VERSION}" --silent \
    && tar -xzf swagger-ui-dist-*.tgz \
    && mkdir /swagger-ui \
    && cp package/swagger-ui.css package/swagger-ui-bundle.js package/favicon-32x32.png package/LICENSE /swagger-ui/

# --- Imagen de la API ------------------------------------------------------------------
FROM php:8.4-apache

# PHP2Shell (CVE-2026-109618 / CVE-2026-109619): se corrigió en 8.4.27.
# El build falla si la imagen base es anterior; reconstruir con `docker compose build --pull`.
RUN php -r 'exit(version_compare(PHP_VERSION, "8.4.27", "<") ? 1 : 0);' \
    || (echo "PHP $(php -r 'echo PHP_VERSION;') es vulnerable a PHP2Shell; usa >= 8.4.27" >&2 && exit 1)

WORKDIR /var/www/html

# pdo_pgsql (única BD de la API), intl (normalización NFC), pcntl (Workerman), redis (phpredis).
# MySQL ya no se usa desde la API (réplica de solo lectura por CDC).
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev libicu-dev unzip \
    && docker-php-ext-install pdo_pgsql intl pcntl \
    && pecl install redis-6.2.0 \
    && docker-php-ext-enable redis \
    && php -r 'exit(defined("PASSWORD_ARGON2ID") && function_exists("sodium_crypto_aead_xchacha20poly1305_ietf_encrypt") ? 0 : 1);' \
    && rm -rf /var/lib/apt/lists/* /tmp/pear

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && printf 'expose_php=Off\nvariables_order="EGPCS"\nmemory_limit=256M\n' > "$PHP_INI_DIR/conf.d/zz-cr-chat.ini" \
    && printf 'ServerTokens Prod\nServerSignature Off\nTraceEnable Off\n' > /etc/apache2/conf-enabled/zz-cr-chat.conf

RUN a2enmod rewrite headers \
    && sed -i 's#DocumentRoot.*$#DocumentRoot /var/www/html/public#' /etc/apache2/sites-enabled/000-default.conf

COPY --from=composer/composer:2-bin /composer /usr/bin/composer

# COMPOSER_DEV=1 instala PHPUnit (entorno de pruebas); en producción se omite.
ARG COMPOSER_DEV=0
COPY ./datos/composer.json ./datos/composer.lock ./
RUN if [ "$COMPOSER_DEV" = "1" ]; then DEV=""; else DEV="--no-dev"; fi \
    && composer install $DEV --no-interaction --no-scripts --no-autoloader --no-progress

# El .env NO se copia a la imagen: se monta como volumen o llega por variables de entorno.
COPY ./datos/src ./src
COPY ./datos/public ./public
COPY ./datos/ws ./ws
COPY ./datos/bin ./bin
COPY ./datos/tests/unit ./tests/unit
COPY ./datos/phpunit.xml.dist ./
COPY ./docs/contratos/openapi.yaml ./openapi/openapi.yaml
COPY --from=swagger /swagger-ui ./swagger-ui
RUN if [ "$COMPOSER_DEV" = "1" ]; then DEV=""; else DEV="--no-dev"; fi \
    && composer dump-autoload --optimize $DEV \
    && chown -R root:root /var/www/html && chmod -R a+rX /var/www/html

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1/api/v1/health > /dev/null || exit 1
