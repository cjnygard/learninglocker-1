#!/bin/bash

set -e

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	if [ -n "$MONGO_PORT_27017_TCP" ]; then
		if [ -z "$LEARNINGLOCKER_DB_HOST" ]; then
			LEARNINGLOCKER_DB_HOST='mongo'
		else
			echo >&2 'warning: both LEARNINGLOCKER_DB_HOST and MONGO_PORT_27017_TCP found'
			echo >&2 "  Connecting to LEARNINGLOCKER_DB_HOST ($LEARNINGLOCKER_DB_HOST)"
			echo >&2 '  instead of the linked mongodb container'
		fi
	fi

	if [ -z "$LEARNINGLOCKER_DB_HOST" ]; then
		echo >&2 'error: missing LEARNINGLOCKER_DB_HOST and MONGO_PORT_27017_TCP environment variables'
		echo >&2 '  Did you forget to --link some_mongo_container:mongo or set an external db'
		echo >&2 '  with -e LEARNINGLOCKER_DB_HOST=hostname:port?'
		exit 1
	fi

	# Check if FQDN/HOSTNAME is set
	: ${APP_URL:=${DOCKERCLOUD_SERVICE_FQDN:=$HOSTNAME}}
	if [ -z "$APP_URL" ]; then
			echo >&2 'error: missing required APP_URL/DOCKERCLOUD_SERVICE_FQDN/HOSTNAME environment variable'
		exit 1
	fi

	# Create SSL certificate files, generate self-signed cert if necessary
	if [ ! -d "/var/www/certs" ]; then
		mkdir -p /var/www/certs
		if [ -z "$AWS_S3_BUCKET_PATH" ]; then
			echo '==> AWS S3 Bucket not found. Generating self-signed SSL certificates.'
			openssl \
				req -new -newkey rsa:4096 -days 365 -nodes -x509 \
				-subj "/C=AU/ST=NSW/L=Sydney/O=Peopleplan Pty Ltd/CN=$APP_URL" \
				-keyout "/var/www/certs/$APP_URL.key" \
				-out "/var/www/certs/$APP_URL.crt"
		else
			echo "==> AWS S3 Bucket found. Downloading SSL certificate from AWS S3 bucket: $AWS_S3_BUCKET_PATH"
			mkdir -p $HOME/.aws
			cat > "$HOME/.aws/config" <<-EOF
				[default]
				aws_access_key_id = $AWS_S3_ACCESS_KEY_ID
				aws_secret_access_key = $AWS_S3_SECRET_ACCESS_KEY
				region = ap-southeast-2
			EOF

			aws s3 sync "$AWS_S3_BUCKET_PATH" /var/www/certs/
			for cert in /var/www/certs/*; do
				mv "$cert" "/var/www/certs/$APP_URL.${cert##*.}"
			done
		fi
		echo "SSLCertificateKeyFile /var/www/certs/$APP_URL.key" >> /etc/apache2/apache2.conf
		echo "SSLCertificateFile /var/www/certs/$APP_URL.crt" >> /etc/apache2/apache2.conf
		echo "SSLCACertificateFile /var/www/certs/$APP_URL.ca-bundle" >> /etc/apache2/apache2.conf
		chmod 700 /var/www/certs
		chmod 600 /var/www/certs/*
	fi

	# Give MONGO some time to boot up
	: ${MONGO_WAIT_TIMEOUT:=${MONGO_WAIT_TIMEOUT:-10}}
	echo -n "Sleeping for $MONGO_WAIT_TIMEOUT seconds while wating for mongodb to come alive..."
	sleep $MONGO_WAIT_TIMEOUT;
	echo 'Done, and awake now.'

	# If we're linked to MongoDB and thus have credentials already, let's use them
        if [ -z "$LEARNINGLOCKER_DB_USER" ]; then
	    LEARNINGLOCKER_DB_USER="${MONGO_ENV_MONGODB_USER:=learninglocker}"
        fi
        if [ -z "$LEARNINGLOCKER_DB_PASSWORD" ]; then
	    LEARNINGLOCKER_DB_PASSWORD="${MONGO_ENV_MONGODB_PASS:=learninglocker}"
        fi
        if [ -z "$LEARNINGLOCKER_DB_NAME" ]; then
	    LEARNINGLOCKER_DB_NAME="${MONGO_ENV_MONGODB_DATABASE:=learninglocker}"
        fi

	if [ -z "$LEARNINGLOCKER_DB_PASSWORD" ]; then
		echo >&2 'error: missing required LEARNINGLOCKER_DB_PASSWORD environment variable'
		echo >&2 '  Did you forget to -e LEARNINGLOCKER_DB_PASSWORD=... ?'
		echo >&2
		echo >&2 '  (Also of interest might be LEARNINGLOCKER_DB_USER and LEARNINGLOCKER_DB_NAME.)'
		exit 1
	fi

	# Setup database connection to mongodb
	if [ ! -e app/config/local/database.php ]; then
		cat > app/config/local/database.php <<-EOF
			<?php
			return [
				'connections' => [
					'mongodb' => [
						'driver'   => 'mongodb',
						'host'     => '${LEARNINGLOCKER_DB_HOST}',
						'port'     => 27017,
						'username' => '$LEARNINGLOCKER_DB_USER',
						'password' => '$LEARNINGLOCKER_DB_PASSWORD',
						'database' => '$LEARNINGLOCKER_DB_NAME'
					],
				]
			];
		EOF
		php artisan migrate
	fi

	# Configure secret key for encryption
	APP_SECRET_KEY=${APP_SECRET_KEY:-CHANGEME12345678}
	if [ ! -e app/config/local/app.php ]; then
		cat > app/config/local/app.php <<-EOF
			<?php
			return [
				'debug' => false,
				'key' => '$APP_SECRET_KEY',
				'url' => 'https://$APP_URL'
			];
		EOF
	fi

	# STMP server configuration
	SMTP_SERVER=${SMTP_SERVER:-smtp.sendgrid.net}
	SMTP_PORT=${SMTP_PORT:-25}
	SMTP_USER=${SMTP_USER:-username}
	SMTP_PASSWORD=${SMTP_PASSWORD:-password}
	EMAIL_FROM_NAME=${EMAIL_FROM_NAME:-Learning Locker LRS Docker Container}
	EMAIL_FROM_ADDRESS=${EMAIL_FROM_ADDRESS:-admin@email.com}

	# Configure SMTP server
	if [ ! -e app/config/local/mail.php ]; then
		cat > app/config/local/mail.php <<-EOF
		<?php
		return [
			'pretend' => false,
			'username' => '$SMTP_USER',
			'password' => '$SMTP_PASSWORD',
			'host' => '$SMTP_SERVER',
			'port' => '$SMTP_PORT',
			'from' => [
				'address' => '$EMAIL_FROM_ADDRESS',
				'name' => '$EMAIL_FROM_NAME'
			]
		];
		EOF
	fi
fi

source /etc/apache2/envvars
exec "$@"
