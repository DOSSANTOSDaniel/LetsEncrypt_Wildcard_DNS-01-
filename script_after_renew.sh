#!/bin/bash

#--------------------------------------------------#
# Script_Name:  script_after_renew.sh                                    
#                                                  #
# Author:       'dossantosjdf@gmail.com'                
# Date:         ven. 14 avril 2023
# Version:      1.0                                #
# Bash_Version: 5.1.4
#--------------------------------------------------#
# Description:
# Ce script permet :
#   * La concaténation de la clé privé et 
#     du certificat fullchain après le renouvellement
#     avec succès de vos certificats.
#
# Documentation/sites:
# * certbot --help renew
# * https://eff-certbot.readthedocs.io/en/stable/index.html
# * https://console.online.net/fr/api/access
# * https://pypi.org/project/certbot-dns-online/                              
#                                                  
# Usage:        ./script_after_renew.sh                                    
#                                                  #    
#--------------------------------------------------#
set -eu

### Variables ###
domain_name='exemple.ex'
prefix_dom="$(echo "$domain_name" | cut -d '.' -f2)"
suffix_dom="$(basename --suffix=".${prefix_dom}" "${domain_name}")"

dir_keys='/etc/letsencrypt/live'

### Main ###
# Concatenation of private key and fullchain certificate file into a single file
sudo cat ${dir_keys}/${domain_name}/fullchain.pem ${dir_keys}/${domain_name}/privkey.pem |
	sudo cp -b --suffix="_$(date +%Y-%m-%d_%H-%M-%S).backup" --remove-destination /dev/stdin ${dir_keys}/${domain_name}/"${suffix_dom}".pem

sudo systemctl reload haproxy

