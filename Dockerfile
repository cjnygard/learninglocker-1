FROM php:5.6-apache
MAINTAINER David Hong <david.hong@peopleplan.com.au>

ENV DEBIAN_FRONTEND=noninteractive

COPY bin/* /usr/local/bin/

# Enable Apache rewrite and expires mods
RUN a2enmod rewrite expires ssl

# Required for mongoDB
# Update and install system/php/python/aws packages (see README.md for more)
# Install AWS cli/s3cmd
# Install mongo client
# Clear apt-get cache
# Install the PHP extensions we need
# Install PHP pecl mongo
# Install composer
# Set recommended PHP.ini settings
# See https://secure.php.net/manual/en/opcache.installation.php
# Download and install Learning Locker
# Upstream tarballs include ./learninglocker-v1.12.1/ so this gives us /var/www/html
RUN apt-key adv --keyserver "keyserver.ubuntu.com" --recv '7F0CEB10' \
 && echo 'deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen' | tee /etc/apt/sources.list.d/mongodb.list \
 && apt-get update \
 && apt-get install -yq \
	curl \
	git \
	groff \
	python \
	python-pip \
	jq \
	openssl \
	libmcrypt-dev \
	libssl-dev \
	libpng12-dev \
	zlib1g-dev \
	libjpeg-dev \
 && pip install awscli s3cmd \
 && apt-get install -yq mongodb-org-shell \
 && echo "mongodb-org-shell hold" | dpkg --set-selections \
 && rm -rf /var/lib/apt/lists/* \
 && docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr \
 && docker-php-ext-install gd opcache zip mcrypt mbstring \
 && docker-php-ext-install pcntl bcmath \
 && docker-php-pecl-install mongo \
 && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
 && { \
	echo 'opcache.memory_consumption=128'; \
	echo 'opcache.interned_strings_buffer=8'; \
	echo 'opcache.max_accelerated_files=4000'; \
	echo 'opcache.revalidate_freq=60'; \
	echo 'opcache.fast_shutdown=1'; \
	echo 'opcache.enable_cli=1'; \
} > /usr/local/etc/php/conf.d/opcache-recommended.ini \
 && mkdir -p /var/www/html \
    && composer global require "laravel/installer=~1.1" \
    && curl -o learninglocker.tar.gz -SL https://github.com/LearningLocker/learninglocker/archive/v1.17.0.tar.gz \
	&& tar -xzf learninglocker.tar.gz -C /var/www/html --strip-components=1 \
	&& rm learninglocker.tar.gz \
	&& chown -R www-data:www-data /var/www/html \
    && composer install

# Setup apache and SSL
#COPY ssl.conf /etc/apache2/mods-available/ssl.conf
#COPY apache2.conf /etc/apache2/apache2.conf

COPY docker-entrypoint.sh /entrypoint.sh

COPY ssl/* /var/www/certs/ 
RUN chmod 700 /var/www/certs \
    && chmod 600 /var/www/certs/*

RUN [ -d /var/log/httpd/logs ] || mkdir -p /var/log/httpd/logs

COPY index.html /var/www/lrs/
RUN chown -R www-data:www-data /var/www/lrs 

# Remove default virtual host server    
RUN rm /etc/apache2/sites-enabled/000-default.conf
COPY learninglocker.conf /etc/apache2/sites-enabled/

RUN a2enmod proxy proxy_http proxy_connect

EXPOSE 443

# grr, ENTRYPOINT resets CMD now
ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
