# Stage 1: build PHP 7.4 from the PHP security team's source backport of the
# fixes for CVE-2026-109618 / CVE-2026-109619 (https://www.php.net/archive/2026.php#2026-10-21-5).
# There is no official 7.4 release containing these fixes. Cachet's dependencies need 7.4.
# Built on alpine 3.15 as PHP 7.4 does not support OpenSSL 3.
FROM alpine:3.15 AS php-build

ARG php_ref=712e60f9edfd03f0960fc4fc3c2c375f42b90aa2
ARG phpredis_ver=5.3.7
ARG apcu_ver=5.1.24

RUN apk add --no-cache --virtual .build-deps \
    git autoconf automake bison re2c file g++ gcc make pkgconf \
    curl-dev freetype-dev icu-dev libjpeg-turbo-dev libpng-dev libsodium-dev \
    libwebp-dev libxml2-dev libxslt-dev libzip-dev oniguruma-dev openssl-dev \
    postgresql-dev sqlite-dev zlib-dev

RUN git init /usr/src/php && cd /usr/src/php && \
    git fetch --depth 1 https://github.com/php/php-src.git ${php_ref} && \
    git checkout FETCH_HEAD && \
    ./buildconf --force && \
    ./configure \
        --prefix=/usr/local \
        --sysconfdir=/etc/php7 \
        --with-config-file-path=/etc/php7 \
        --with-config-file-scan-dir=/etc/php7/conf.d \
        --disable-cgi --disable-phpdbg \
        --enable-fpm \
        --enable-bcmath --enable-intl --enable-mbstring --enable-mysqlnd \
        --enable-opcache --enable-soap --enable-sockets \
        --with-curl --with-freetype --with-jpeg --with-webp --enable-gd \
        --with-openssl --with-pdo-mysql=mysqlnd --with-mysqli=mysqlnd \
        --with-pdo-pgsql --with-pdo-sqlite --with-sqlite3 \
        --with-sodium --with-zip --with-zlib --with-xsl && \
    make -j"$(nproc)" && make install && \
    strip /usr/local/bin/php /usr/local/sbin/php-fpm

RUN mkdir -p /etc/php7/conf.d /etc/php7/php-fpm.d && \
    wget -qO- https://github.com/phpredis/phpredis/archive/refs/tags/${phpredis_ver}.tar.gz | tar xz -C /usr/src && \
    wget -qO- https://github.com/krakjoe/apcu/archive/refs/tags/v${apcu_ver}.tar.gz | tar xz -C /usr/src && \
    for ext in phpredis-${phpredis_ver} apcu-${apcu_ver}; do \
        cd /usr/src/$ext && /usr/local/bin/phpize && ./configure --with-php-config=/usr/local/bin/php-config && \
        make -j"$(nproc)" && make install; \
    done

# Stage 2: runtime image
FROM nginx:1.21.6-alpine

EXPOSE 8000
CMD ["/sbin/entrypoint.sh"]

ARG cachet_ver
ARG archive_url

ENV cachet_ver ${cachet_ver}
ENV archive_url ${archive_url:-https://github.com/klarrio/Cachet/archive/refs/tags/${cachet_ver}.tar.gz}

ENV COMPOSER_VERSION 2.2.25

RUN apk add --no-cache --update \
    postgresql-client \
    mysql-client \
    libcurl freetype icu-libs libjpeg-turbo libpng libsodium libwebp libxml2 \
    libxslt libzip oniguruma openssl sqlite-libs libpq zlib \
    wget sqlite git bash grep \
    supervisor && \
    apk upgrade --no-cache

COPY --from=php-build /usr/local/bin/php /usr/local/bin/php
COPY --from=php-build /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm
COPY --from=php-build /usr/local/lib/php /usr/local/lib/php
COPY conf/php.ini /etc/php7/php.ini
COPY conf/php-fpm.conf /etc/php7/php-fpm.conf
RUN mkdir -p /etc/php7/conf.d /etc/php7/php-fpm.d /var/log/php7 && php -v && php -m

# forward request and error logs to docker log collector
RUN ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    ln -sf /dev/stdout /var/log/php7/error.log && \
    ln -sf /dev/stderr /var/log/php7/error.log

RUN adduser -S -s /bin/bash -u 1001 -G root www-data

RUN touch /var/run/nginx.pid && \
    chown -R www-data:root /var/run/nginx.pid /etc/php7/php-fpm.d

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

COPY conf/php-fpm-pool.conf /etc/php7/php-fpm.d/www.conf
COPY conf/supervisord.conf /etc/supervisor/supervisord.conf
COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/nginx-site.conf /etc/nginx/conf.d/default.conf
COPY conf/.env.docker /var/www/html/.env
COPY entrypoint.sh /sbin/entrypoint.sh

RUN php /bin/composer.phar install --ignore-platform-reqs && \
    rm -rf bootstrap/cache/*

USER root
RUN chmod g+rwx /var/run/nginx.pid && \
    chmod -R g+rw /var/www /usr/share/nginx/cache /var/cache/nginx /var/lib/nginx/ /etc/php7/php-fpm.d storage
USER 1001
