FROM nginx:1.30.6-alpine3.24

EXPOSE 8000
CMD ["/sbin/entrypoint.sh"]

ARG cachet_ver
ARG archive_url

ENV cachet_ver ${cachet_ver}
ENV archive_url ${archive_url:-https://github.com/klarrio/Cachet/archive/refs/tags/${cachet_ver}.tar.gz}

ENV COMPOSER_VERSION 2.8.12

RUN apk add --no-cache --update \
    postgresql-client \
    mysql-client \
    php83 \
    php83-pecl-redis \
    php83-pecl-apcu \
    php83-bcmath \
    php83-dom \
    php83-ctype \
    php83-curl \
    php83-fpm \
    php83-fileinfo \
    php83-gd \
    php83-iconv \
    php83-intl \
    php83-mbstring \
    php83-mysqlnd \
    php83-opcache \
    php83-openssl \
    php83-pdo \
    php83-pdo_mysql \
    php83-pdo_pgsql \
    php83-pdo_sqlite \
    php83-phar \
    php83-posix \
    php83-session \
    php83-sqlite3 \
    php83-simplexml \
    php83-soap \
    php83-xml \
    php83-xmlwriter \
    php83-zip \
    php83-tokenizer \
    php83-sodium \
    curl sqlite wget git bash grep supervisor \
 && ln -sf /usr/bin/php83 /usr/bin/php

# forward request and error logs to docker log collector
RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    ln -sf /dev/stdout /var/log/php83/error.log && \
    ln -sf /dev/stderr /var/log/php83/error.log

RUN adduser -S -s /bin/bash -u 1001 -G root www-data

RUN touch /var/run/nginx.pid && \
    chown -R www-data:root /var/run/nginx.pid /etc/php83/php-fpm.d

RUN mkdir -p /var/www/html && \
    mkdir -p /usr/share/nginx/cache && \
    mkdir -p /var/cache/nginx && \
    mkdir -p /var/lib/nginx && \
    chown -R www-data:root /var/www /usr/share/nginx/cache /var/cache/nginx /var/lib/nginx/

# Install composer
RUN wget https://getcomposer.org/installer -O /tmp/composer-setup.php && \
    wget https://composer.github.io/installer.sig -O /tmp/composer-setup.sig && \
    php -r "if (hash('SHA384', file_get_contents('/tmp/composer-setup.php')) !== trim(file_get_contents('/tmp/composer-setup.sig'))) { unlink('/tmp/composer-setup.php'); echo 'Invalid installer' . PHP_EOL; exit(1); }" && \
    php /tmp/composer-setup.php --version=$COMPOSER_VERSION --install-dir=bin && \
    php -r "unlink('/tmp/composer-setup.php');"

WORKDIR /var/www/html/
USER 1001

RUN wget ${archive_url} && \
    tar xzf ${cachet_ver}.tar.gz --strip-components=1 && \
    chown -R www-data:root /var/www/html && \
    rm -r ${cachet_ver}.tar.gz

COPY conf/php-fpm-pool.conf /etc/php83/php-fpm.d/www.conf
COPY conf/supervisord.conf /etc/supervisor/supervisord.conf
COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/nginx-site.conf /etc/nginx/conf.d/default.conf
COPY conf/.env.docker /var/www/html/.env
COPY entrypoint.sh /sbin/entrypoint.sh

# Cachet's locked dependencies target PHP 7.4:
# - doctrine/dbal 2.6 is incompatible with PHP 8, bump to 2.13
# - Laravel 6 turns PHP 8 deprecation notices into fatal errors, so exclude them
RUN sed -i 's#"doctrine/dbal": "2.6"#"doctrine/dbal": "^2.13"#' composer.json && \
    php /bin/composer.phar update doctrine/dbal nesbot/carbon --with-dependencies --ignore-platform-reqs --no-plugins --no-scripts && \
    sed -i 's/error_reporting(-1)/error_reporting(E_ALL \& ~E_DEPRECATED \& ~E_USER_DEPRECATED)/' vendor/laravel/framework/src/Illuminate/Foundation/Bootstrap/HandleExceptions.php && \
    php /bin/composer.phar install --ignore-platform-reqs --no-plugins && \
    rm -rf bootstrap/cache/*

USER root
RUN chmod g+rwx /var/run/nginx.pid && \
    chmod -R g+rw /var/www /usr/share/nginx/cache /var/cache/nginx /var/lib/nginx/ /etc/php83/php-fpm.d storage
USER 1001
