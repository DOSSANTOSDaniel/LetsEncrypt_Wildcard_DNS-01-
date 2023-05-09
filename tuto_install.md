# Certificats Let’s Encrypt Wildcard avec Certbot en utilisant un challenge DNS-01 automatique sur online.net à utiliser avec un reverse-proxy (Haproxy)

## Contexte
Le but est de créer des certificats wildcard valables pour tous les sous-domaines d'un domaine donné, de manière automatique, pas besoin de créer un nouveau certificat pour chaque nouveau sous-domaine.

Dans ce tutoriel, on va prendre comme exemple la création d'un certificat wildcard pour le domaine exemple.ex dans le but d'avoir deux sous domaines certifiés :
1. pve.exemple.ex pour un serveur Proxmox.
2. next.exemple.ex pour un serveur Nextcloud.

![Haproxy](ha.png)

Pour cet exemple, j’utilise Online.net nouvellement appelé Scaleway pour acquérir un nom de domaine et configurer mes zones DNS.

J'utilise mon serveur Haproxy en tant que reverse proxy.

## Les besoins
* Acheter un nom de domaine chez <https://console.online.net/fr/login>
* Un ordinateur avec Ubuntu/Debian avec Haproxy.

Récupération du Token :
Aller sur la page <https://console.online.net/fr/api/access> pour récupérer le token permettant de s'authentifier auprès de l'API d'online.net.

## Le plugin à utiliser pour le challenge DNS-01 sur online.net
Le plugin certbot-dns-online permet à Certbot de se connecter à l'API d'online.net dans le but de modifier les zones DNS, c'est de cette manière qu'on pourra utiliser le challenge DNS-01 et ainsi avoir un renouvellement des certificats automatiquement.

certbot-dns-online est un plugin fourni par d'autres développeurs que ceux du projet Certbot,
c'est une version expérimentale, mais déjà largement utilisée.

Liens du plugin : <https://pypi.org/project/certbot-dns-online/>

## Désinstallation d'anciennes versions de Certbot
```bash
sudo apt-get remove certbot --purge -y
```

Vérifier s'il y a des services liés à Certbot sur Systemd.
```bash
sudo systemctl is-active certbot.timer
sudo systemctl is-active certbot.service
```

Si c'est le cas, alors il faut les désactiver et par la suite les supprimer.
```bash
sudo systemctl stop certbot.timer
sudo systemctl disable certbot.timer
sudo rm -rf /etc/systemd/system/certbot.timer

sudo systemctl stop certbot.service
sudo systemctl disable certbot.service
sudo rm -rf /etc/systemd/system/certbot.service

sudo systemctl daemon-reload
```

Si jamais vous avez déjà obtenu un certificat par le passé, vous pouvez soit le supprimer, soit le conserver et continuer.

Pour supprimer un certificat.
```bash 
sudo certbot delete --cert-name exemple.ex
sudo rm -rf /etc/letsencrypt/live/exemple.ex
```

## Installation des dépendances
```bash
sudo apt-get update
sudo apt-get install python3 python3-venv libaugeas0 -y
```

```bash
sudo python3 -m venv /opt/certbot/
sudo /opt/certbot/bin/pip install --upgrade pip --quiet

sudo /opt/certbot/bin/pip install certbot certbot-dns-online lexicon dns-lexicon[full] zope
```

## Création des certificats et configurations
Lien symbolique de Certbot vers le $PATH.
```bash
sudo ln -s /opt/certbot/bin/certbot /usr/bin/certbot
```

Création d'un dossier pour accueillir le fichier d'authentification à utiliser pour se connecter à l'API d'online.net.
```bash
sudo mkdir -p /etc/letsencrypt/.secrets
```

Écrire le token dans le fichier d'authentification (online.ini). 
Ajouter cette ligne en remplaçant les étoiles par votre token.
```bash
echo 'dns_online_token = ****************************************' > /etc/letsencrypt/.secrets/online.ini
```

Sécurisation du fichier.
```bash
sudo chown -R root:root /etc/letsencrypt/.secrets 
sudo chmod -R 600 /etc/letsencrypt/.secrets
```

Début de la création des certificats. 
```bash
sudo certbot certonly \
  --authenticator dns-online \
  --dns-online-credentials "/etc/letsencrypt/.secrets/online.ini" \
  --dns-online-propagation-seconds "900" \
  --agree-tos \
  --rsa-key-size "4096" \
  --domains "*.exemple.ex,exemple.ex" \
  --email "host@exemple.com" \
  --verbose
```
Adapter avec votre nom de domaine et votre adresse email.

La valeur 900 indique que Certbot doit attendre la propagation des nouvelles entrées DNS pendant 15 minutes.

Une fois que vous avez votre certificat, vous pouvez l'utiliser avec n'importe quel autre service.


Concaténation de la clé privée et du certificat fullchain en un seul fichier dans le but de l'utiliser plus tard avec Haproxy en mode reverse proxy.

 
```bash
sudo cat /etc/letsencrypt/live/exemple.ex/fullchain.pem /etc/letsencrypt/live/exemple.ex/privkey.pem > /etc/letsencrypt/live/exemple.ex/suffix_dom.pem
```

Recharger la configuration d'Haproxy.
```bash
sudo systemctl reload haproxy
```

Afficher les certificats créés.
```bash
sudo certbot certificates
```

## Création d'un script pour le renouvellement automatique du certificat
Chaque certificat expire au bout de 90 jours.
Certbot va être lancé pour vérifier tous les jours si les certificats sont encore valides, à moins de 30 jours de la date d'expiration, Certbot renouvelle les certificats installés.

Pour le renouvellement des certificats, Certbot va utiliser les mêmes options qui ont été utilisées à la création de ces certificats.

Création d'un script pour l'automatisation du renouvellement des certificats.
```bash
nano script_after_renew.sh
```

Modifier juste la variable domain_name pour l'adapter selon votre nom de domaine.
```bash
#!/bin/bash

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
```

Rendre le script exécutable.
```bash
sudo chmod +x script_after_renew.sh
```

Copier le script dans /etc/letsencrypt/renewal-hooks/deploy/, le dossier deploy peut contenir des scripts, ces scripts sont exécutés une fois le renouvellement des certificats terminé avec succès.

Le script sera donc lancé seulement si le renouvellement des certificats s'est déroulé sans erreurs.
```bash
sudo cp script_after_renew.sh /etc/letsencrypt/renewal-hooks/deploy/
```

## Configuration de systemd
Création du timer(déclencheur), on va utiliser systemd pour mettre en plage les vérifications quotidienne des certificats avec la commande(certbot --quiet renew --cert-name exemple.ex).

La vérification se déclenche tous les jours à 4h du matin, à ce moment-là, le fichier timer va lancer le service (certbot.service) et ainsi lancer la vérification de validité des certificats.
```bash
nano /etc/systemd/system/certbot.timer
```

```bash
[Unit]
Description=Run renew certbot every day
Documentation=https://www.freedesktop.org/software/systemd/man/systemd.timer.html

[Timer]
OnCalendar=*-*-* 4:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Le fichier service, quand il sera déclenché par le timer associé, il lancera Certbot qui fera un test pour vérifier si le certificat est encore à jour, sinon il démarrera le renouvellement.
```bash
nano /etc/systemd/system/certbot.service
```

```bash
[Unit]
Description=Certbot renew
Documentation=https://www.freedesktop.org/software/systemd/man/systemd.service.html

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot --quiet renew --cert-name exemple.ex

[Install]
WantedBy=multi-user.target
```
Si on n'indique pas l'option --cert-name alors tous les certificats seront vérifiés et s'ils ne sont plus valides, ils seront tous renouvelés.

Applications des droits pour timer et service.
```bash
sudo chmod 644 /etc/systemd/system/certbot.timer
sudo systemctl enable certbot.timer
```

```bash
sudo chmod 644 /etc/systemd/system/certbot.service
sudo systemctl enable certbot.service
```

Exemple de l'arborescence des fichiers.
```
/etc/systemd/
|
├── system
│   ├── certbot.service
│   ├── certbot.timer
│   ├── multi-user.target.wants
│   │   └── certbot.service -> /etc/systemd/system/certbot.service
│   └── timers.target.wants
│       └── certbot.timer -> /etc/systemd/system/certbot.timer
└── user
    └── sockets.target.wants


/etc/letsencrypt/
|
├── live
│   ├── exemple.ex
│   │   ├── cert.pem -> ../../archive/exemple.ex/cert2.pem
│   │   ├── chain.pem -> ../../archive/exemple.ex/chain2.pem
│   │   ├── exemple.pem
│   │   ├── exemple.pem_2023-04-12_18-37-05.backup
│   │   ├── fullchain.pem -> ../../archive/exemple.ex/fullchain2.pem
│   │   ├── privkey.pem -> ../../archive/exemple.ex/privkey2.pem
│   │   └── README
│   └── README
├── renewal
│   └── exemple.ex.conf
└── renewal-hooks
    ├── deploy
    │   └── after_renew.sh
    ├── post
    └── pre
```

Afficher le statut du timer.
```bash
sudo systemctl status certbot.timer
```

Par la suite, il ne vous reste plus qu'à modifier votre zone DNS afin de créer des alias CNAME pour chaque sous domaine que vous voulez utiliser.

