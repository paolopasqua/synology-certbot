#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

if [[ -z $SYNO_DESCRIPTION ]]; then
  echo "No description of certificate in Synology settings set, please fill -e 'SYNO_DESCRIPTION=cert_example.com'"
  exit 1
fi

if [[ -z $DOMAIN ]]; then
  echo "No domains set, please fill -e 'DOMAINS=example.com'"
  exit 1
fi

if [[ -z $EMAIL_ADDRESS ]]; then
  echo "No email set, please fill -e 'EMAIL_ADDRESS=your@email.tld'"
  exit 1
fi

if [[ -z $CERTBOT_DIR_PATH ]]; then
  echo "No certbot dir path set, please fill -e 'CERTBOT_DIR_PATH=/etc/letsencrypt'"
  exit 1
fi

if [[ -z $LOG_PATH ]]; then
  echo "No webroot path set, please fill -e 'LOG_PATH=/var/log'"
  exit 1
fi

if [[ -z $CHALLENGE_TYPE ]]; then
  echo "No domain ownership challenge set, please fille -e 'CHALLENGE_TYPE=HTTP' or -e 'CHALLENGE_TYPE=CLOUDFLARE'"
  exit 1
fi

if [ ${CHALLENGE_TYPE} = "HTTP" ]
then
	if [[ -z $WEBROOT_PATH ]]; then
	  echo "No secrets path set, please fill -e 'WEBROOT_PATH=/tmp/letsencrypt'"
	  exit 1
	fi
else
	if [[ -z $SECRETS_PATH ]]; then
	  echo "No secrets path set, please fill -e 'SECRETS_PATH=/.secrets'"
	  exit 1
	fi
fi

if [[ -z $EXP_LIMIT ]]; then
  echo "[INFO] No expiration limit set, using default: 30"
  EXP_LIMIT=30
fi

exp_limit="${EXP_LIMIT:-30}"

syno_cert_folder="/usr/syno/etc/certificate/_archive"
info_path="${syno_cert_folder}/INFO"

syno_cert_id=$(grep -zoP "\".*\" : {.*\n.*\"desc\" : \"${SYNO_DESCRIPTION}\"" $info_path | cut -d '"' -f 2 | head -n1)
if [ -z "$syno_cert_id" ]; 
then
	syno_cert_id=$(openssl rand -hex 3)
	while [ $(grep -c "$syno_cert_id" $info_path) -gt 0 ]
	do
			syno_cert_id=$(openssl rand -hex 3)
	done
	
	echo "[INFO] Not found id for certificate description ${SYNO_DESCRIPTION}. Generate new certificate id ${syno_cert_id}"
else
	echo "[INFO] Found id ${syno_cert_id} for certificate description"
fi

if [ -z "$syno_cert_id" ]; 
then
	echo "[ERROR] No id"
	exit 1
fi

cert_dir="${syno_cert_folder}/${syno_cert_id}"
echo "[INFO] Folder of certificate: ${cert_dir}"

first_char=$(echo "${DOMAIN}" | cut -c-1)
if [ "${first_char}" = "*" ]
then
	clear_domain=$(echo "$DOMAIN" | cut -c3-)
else
	clear_domain="$DOMAIN"
fi

restart_synoservices() {
    echo "[INFO] Restarting Services"
	synosystemctl restart nginx;
}

fix_permissions() {
    echo "[INFO] Fixing permissions"
	chown -R ${CHOWN:-root:root} ${cert_dir}
	find ${cert_dir} -type d -exec chmod 755 {} \;
	find ${cert_dir} -type f -exec chmod ${CHMOD:-644} {} \;
}

copy_certificate() {
    echo "[INFO] Installing certificate"
	gen_cert_dir="$CERTBOT_DIR_PATH/live/$clear_domain";

	#check if exist and delete
	if [ $(ls $cert_dir | grep -c -e ".pem") -gt 0 ]; then
		cp -r $cert_dir/*.pem "$cert_dir.bak"
	fi
	
	cp "$gen_cert_dir/fullchain.pem" "$cert_dir/fullchain.pem"
	cp "$gen_cert_dir/chain.pem" "$cert_dir/chain.pem"
	cp "$gen_cert_dir/cert.pem" "$cert_dir/cert.pem"
	cp "$gen_cert_dir/privkey.pem" "$cert_dir/privkey.pem"
}

gen_cert() {
	if [ ${CHALLENGE_TYPE} = "HTTP" ]
	then
		gen_cert_http
	else
		gen_cert_cloudflare
	fi
	copy_certificate
	fix_permissions
	restart_synoservices
}

gen_cert_http() {
    docker run --rm --name temp_certbot \
        -v "${CERTBOT_DIR_PATH}:/etc/letsencrypt" \
        -v "${WEBROOT_PATH}:/tmp/letsencrypt" \
		-v "${LOG_PATH}:/var/log" \
        certbot/certbot:latest  \
		certonly \
		--webroot --agree-tos --renew-by-default  \
		--preferred-challenges http-01 \
		--server https://acme-v02.api.letsencrypt.org/directory --text \
		--email ${EMAIL_ADDRESS} -w /tmp/letsencrypt \
		-d ${DOMAIN}
}

gen_cert_cloudflare() {
	docker run --rm --name temp_certbot \
		-v "${CERTBOT_DIR_PATH}:/etc/letsencrypt" \
		-v "${LOG_PATH}:/var/log" \
		-v "${SECRETS_PATH}:/.secrets" \
		certbot/dns-cloudflare:latest  \
		certonly \
		--dns-cloudflare \
		--dns-cloudflare-credentials /.secrets/cloudflare.ini \
		--dns-cloudflare-propagation-seconds 60 \
		--agree-tos --renew-by-default \
		--server https://acme-v02.api.letsencrypt.org/directory \
		--text --email ${EMAIL_ADDRESS} \
		-d ${DOMAIN}
}

install_new_cert() {
	cp $info_path "$info_path.bak"
	
	act_info=$(cat $info_path | head -n-1)
	act_info=$(echo -e "$act_info ,\n\"$syno_cert_id\" : { \"desc\" : \"${SYNO_DESCRIPTION}\", \"services\" : [], \"user_deletable\" : \"true\" }\n}")
	echo $act_info > "$info_path"
	mkdir "$syno_cert_folder/$syno_cert_id"
}

cert_check() {

    cert_file="$cert_dir/fullchain.pem";

    echo "START check";
    echo "file: $cert_file";

    if [[ -e $cert_file ]]; then

        echo "Checking expiration date for $clear_domain..."
        exp=$(date -d "`openssl x509 -in $cert_file -text -noout|grep "Not After"|cut -c 25-`" +%s)
        datenow=$(date -d "now" +%s)
        days_exp=$[ ( $exp - $datenow ) / 86400 ]

    else
		
		echo "[INFO] certificate file not found for domain $clear_domain. Installing new certificate."
		install_new_cert
		days_exp=-1
		
    fi

	if [ "$days_exp" -gt "$exp_limit" ] ; then
		echo "The certificate is up to date, no need for renewal ($days_exp days left)."
	else
		if [ "$days_exp" -ge 0 ] ; then
			echo "The certificate for $clear_domain expires in $days_exp days. Starting renewal script..."
		else
			echo "There's no certificate for $clear_domain. Starting generate script..."
		fi
		gen_cert
		echo "Process finished for domain $clear_domain"
	fi
}

echo "--- start. $(date)"
cert_check
