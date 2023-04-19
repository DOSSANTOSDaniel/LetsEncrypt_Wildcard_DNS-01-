#!/bin/bash

#--------------------------------------------------#
# Script_Name:  install_certs.sh                                    
#                                                  #
# Author:       'dossantosjdf@gmail.com'                
# Date:         ven. 14 avril 2023
# Version:      1.0                                #
# Bash_Version: 5.1.4
#--------------------------------------------------#
# Description:
# Ce script permet :
#   * Installation de Certbot.
#   * Installation du plugin certbot-dns-online qui
#       permet de se connecter à l'api de online.net
#	dans le but d'utiliser un challenge DNS-01.
#   * Mise en place du renouvellement automatique
#       de vos certificats.
#   * Création des certicicats wildcard pour un domaine
#       *.exemple.fr en utilisant un challenge DNS-01
#	de manière complétement automatique.
#
# Documentation/sites:
# * https://eff-certbot.readthedocs.io/en/stable/index.html
# * https://console.online.net/fr/api/access
# * https://pypi.org/project/certbot-dns-online/                              
#                                                  
# Usage:        ./install_certs.sh                                    
#                                                  #    
#--------------------------------------------------#

set -eu

### Variables ###
domain_name=''
email_admin=''

rsa_key_size='4096'
time_dns_prop='900' # Seconds (15 min)

# https://console.online.net/fr/api/access
online_token=''

dir_keys='/etc/letsencrypt/live'
dir_online_auth='/etc/letsencrypt/.secrets'
file_online_auth="${dir_online_auth}/online.ini"

file_sysd_timer='certbot.timer'
file_sysd_service='certbot.service'

# Script after sucess renew
file_script_deploy='script_after_renew.sh'
dir_renew_hook_deploy='/etc/letsencrypt/renewal-hooks/deploy/'

apt_pkgs='python3 python3-venv libaugeas0'
pip_pkgs='certbot certbot-dns-online lexicon dns-lexicon[full] zope'

### Main ###
clear

echo "
    Générer un certificat wildcard avec Certbot,
    en utilisant un challenge DNS-01 sur Online.net automatiquement.
"

echo -e "\n----------------------------------"
echo -e "Insérer un nom de domaine pas un sous-domaines \n"
read -r -p "Domaine: " domain_name
echo -e "\n----------------------------------\n"
read -r -p "Email: " email_admin
echo -e "\n----------------------------------"
echo -e "Pour récupérer le token : https://console.online.net/fr/api/access \n"
read -s -r -p "API Token: " online_token
echo -e "\n----------------------------------\n"

# Example with toto@site.massy.fr
# Total characters domain: 64 - 1(>)mailto = 63 (massy.fr)
# Total characters sub-domain + domain: 191 + 63 = 254 (site.massy.fr)
# Total local characters: 64 - 1(<)mailto = 63 (toto)
# 1 character for @
# Allowed characters: A-Z,a-z,0-9,.,- and @
# You need at least one point on the set
# The local name must not start with: 0-9,-,.
# The domain must not start with: 0-9,-,. and also finish
# No number in TLD extension, top level domain (.fr)
regex_domain='^[a-zA-Z]\.?([a-zA-Z0-9-]\.?){1,49}[a-zA-Z0-9]\.[a-zA-Z]{2,10}$'
regex_email='^[a-z]\.?([a-z0-9-]\.?){1,30}[a-z0-9]@[a-z]\.?([a-z0-9-]\.?){1,100}[a-z0-9]\.[a-z]{2,24}$'

# The token is 40 characters  
regex_token='^[a-z0-9]{40}$'

if [[ -z $domain_name || -z $email_admin || -z $online_token ]]
then
  echo "Les champs Domaine, Email, API Token doivent être complétés"
  exit 1
fi

if [[ $domain_name =~ $regex_domain ]]
then
  if (host -t A "$domain_name")
  then
      only_domain="$(nslookup "$domain_name" | awk '/^Name:/{print $2}' 2> /dev/null)"
      domain_name="$only_domain"
  else
      echo "Le domaine n'est pas valide !"
  fi
else
  echo "La syntaxe du nom de domaine n'est pas valide !"
  echo "Exemple: exemple.fr"
  echo "Caractères autorisés: a-z, A-Z, 0-9, -, ."        
  exit 1
fi

if [[ $email_admin =~ $regex_email ]]
then
  if ! (host -t MX "$(echo "$email_admin" | cut -d'@' -f2)")
  then
    echo "L'adresse email n'est pas valide !"
    exit 1
  fi
else
  echo "La syntaxe de l'adresse email n'est pas valide !"
  echo "Exemple: host@domain.com"
  echo "Caractères autorisés: a-z, A-Z, 0-9, -, ., @"           
  exit 1
fi

if ! [[ $online_token =~ $regex_token ]]
then
  echo "La syntax de du token n'est pas valide !"
  echo "Exemple: f5ddgfd5f8d4gd..."   
  exit 1
fi

clear 
echo "
               Résumé
    -----------------------------
    Nom de domaine : $domain_name
    Adresse mail   : $email_admin
    Token privé    : $online_token
    -----------------------------
"
read -r -p "Appuyer sur Enter pour continuer, si non Ctrl+c pour quitter !"

prefix_dom="$(echo "$domain_name" | cut -d '.' -f2)"
suffix_dom="$(basename --suffix=".${prefix_dom}" "$domain_name")"

# Installing and configuration of dependencies
# Delete cerbot
sudo apt-get remove certbot --purge -y

# Delete certbot configuration of systemd
if (sudo systemctl is-active $file_sysd_timer)
then
  for service in "$file_sysd_service" "$file_sysd_timer"
  do
    sudo systemctl stop $service
    sudo systemctl disable $service
    sudo rm -rf /etc/systemd/system/${service}
  done
fi

# Remove certificates if exist
if [[ -d ${dir_keys}/${domain_name} ]]
then
  echo -e "\n Des clés existent déjà pour $domain_name \n"
  echo "Pour supprimer le certificat : "
  echo "sudo certbot delete --cert-name $domain_name"
  echo "sudo rm -rf /etc/letsencrypt/live/${domain_name}"
  exit 0
fi

# Install Certbot and dependencies
# Installing dependencies
echo -e "\n Vérification des dépendances ... \n"

if (command -v apt-get 2> /dev/null)
then
  for appinstall in $apt_pkgs
  do
    if ! (sudo dpkg -L "$appinstall" > /dev/null) || ! (command -v "$appinstall" > /dev/null)
    then
      sudo apt-get update -qq
      if ! (sudo apt-get install "$appinstall" -qqy)
      then
        echo -e "\n Installation de $appinstall Impossible! \n"
        exit 1
      fi
    fi
  done
else
  echo "Ce script est utilisable seulement sur Ubuntu ou Debian"
  exit 1
fi

# Install Certbot via pip
sudo python3 -m venv /opt/certbot/
sudo /opt/certbot/bin/pip install --upgrade pip --quiet

# The certbot plugin allows you to configure a DNS challenge on the online.net provider 
# https://pypi.org/project/certbot-dns-online/
for pkg in $pip_pkgs
do
  sudo /opt/certbot/bin/pip install "$pkg" --quiet
done

# Link for certbot to appear in PATH
sudo ln -s /opt/certbot/bin/certbot /usr/bin/certbot

# Creation of the file that will contain the authentication information for the online.net API
sudo mkdir -p $dir_online_auth

# Write authentication information in /etc/letsencrypt/.secrets/online.ini
# Creating an automatic backup of the online.ini file
sudo echo "dns_online_token = $online_token" |
	sudo cp -b --suffix="_$(date +%Y-%m-%d_%H-%M-%S).backup" --remove-destination /dev/stdin $file_online_auth

# Secure authentication file access
sudo chown -R root:root $dir_online_auth 
sudo chmod -R 600 $dir_online_auth

# Certbot command
sudo certbot certonly \
  --authenticator dns-online \
  --dns-online-credentials "$file_online_auth" \
  --dns-online-propagation-seconds "$time_dns_prop" \
  --agree-tos \
  --rsa-key-size "$rsa_key_size" \
  --domains "*.${domain_name},${domain_name}" \
  --email "$email_admin" \
  --verbose

# Concatenation of private key and fullchain certificate file into a single file
sudo cat "${dir_keys}"/"${domain_name}"/fullchain.pem "${dir_keys}"/"${domain_name}"/privkey.pem |
	sudo cp -b --suffix="_$(date +%Y-%m-%d_%H-%M-%S).backup" --remove-destination /dev/stdin "${dir_keys}"/"${domain_name}"/"${suffix_dom}".pem

# Reload Haproxy
sudo systemctl reload haproxy

# Copy of script to run after successful renewal
if (sudo sed -i "s/domain_name=.*/domain_name=${domain_name}/" $file_script_deploy)
then
  sudo cp --remove-destination $file_script_deploy $dir_renew_hook_deploy
fi

# Config systemd services
cat << EOF | sudo cp --remove-destination /dev/stdin /etc/systemd/system/${file_sysd_timer}
[Unit]
Description=Run renew certbot every day
Documentation=systemd.service(5),https://www.freedesktop.org/software/systemd/man/systemd.timer.html

[Timer]
OnCalendar=*-*-* 4:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat << EOF | sudo cp --remove-destination /dev/stdin /etc/systemd/system/${file_sysd_service}
[Unit]
Description=Certbot renew
Documentation=https://www.freedesktop.org/software/systemd/man/systemd.service.html

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot --quiet renew --cert-name $domain_name

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

for sysd_file in $file_sysd_timer $file_sysd_service
do
  sudo chmod 644 /etc/systemd/system/"${sysd_file}"
  sudo systemctl enable "$sysd_file"
done

# Informations
echo -e "\n Certificats \n"
sudo certbot certificates

echo -e "\n Statut du déclencheur permettant le renouvellement \n"
sudo systemctl status "$file_sysd_timer"