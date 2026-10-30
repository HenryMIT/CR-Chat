FROM php:8.4-apache

# PHP2Shell (CVE-2026-109618 / CVE-2026-109619): se corrigió en 8.4.27.
# El build falla si la imagen base es anterior; reconstruir con `docker compose build --pull`.
RUN php -r 'exit(version_compare(PHP_VERSION, "8.4.27", "<") ? 1 : 0);' \
    || (echo "PHP $(php -r 'echo PHP_VERSION;') es vulnerable a PHP2Shell; usa >= 8.4.27" >&2 && exit 1)

WORKDIR /var/www/html

RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev unzip \
    && docker-php-ext-install pdo_mysql pdo_pgsql \
    && rm -rf /var/lib/apt/lists/*

RUN a2enmod rewrite \
    && sed -i 's#DocumentRoot.*$#DocumentRoot /var/www/html/public#' /etc/apache2/sites-enabled/000-default.conf

COPY --from=composer/composer:latest-bin /composer /usr/bin/composer

COPY ./datos/composer.json .
RUN composer install --no-dev --no-interaction --no-scripts --no-autoloader

# El .env NO se copia a la imagen: se monta como volumen desde docker-compose
COPY ./datos/src ./src
COPY ./datos/public ./public
RUN composer dump-autoload --optimize --no-dev
