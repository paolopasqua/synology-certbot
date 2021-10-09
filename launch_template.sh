#!/bin/bash

export SYNO_DESCRIPTION="example.com";
export DOMAIN="*.example.com";
export EMAIL_ADDRESS="admin@example.com";
export CERTBOT_DIR_PATH="/path/to/your/certbot/etc/letsencrypt";
export LOG_PATH="/path/to/your/certbot/log";
export CHALLENGE_TYPE="CLOUDFLARE"; # or HTTP
export SECRETS_PATH="/path/to/your/certbot/.secrets"; # or WEBROOT_PATH
export EXP_LIMIT="35";

bash "/path/to/your/syno-certbot.sh"
