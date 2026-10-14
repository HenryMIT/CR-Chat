FROM php:8.4-apache

WORKDIR /var/www/html

RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev zip unzip git \
    && docker-php-ext-install pdo pdo_mysql pdo_pgsql \
    && rm -rf /var/lib/apt/lists/*

RUN a2enmod rewrite \
    && sed -i 's#DocumentRoot.*$#DocumentRoot /var/www/html/public#' /etc/apache2/sites-enabled/000-default.conf

COPY --from=composer/composer:latest-bin /composer /usr/bin/composer

COPY ./datos/composer.json .
RUN composer install --no-dev --no-interaction --no-scripts --no-autoloader

# El .env NO se copia a la imagen: se monta como volumen desde docker-compose
COPY ./datos/.htaccess .
COPY ./datos/src ./src
COPY ./datos/public ./public
RUN composer dump-autoload --optimize --no-dev
