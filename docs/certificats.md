# Certificats fournis (`TLS_MODE=custom`)

Avec `TLS_MODE=custom`, Traefik sert la plateforme en HTTPS (port 443) avec un certificat fourni par
l'opérateur, typiquement émis par la PKI de l'organisation. Le port 80 redirige vers HTTPS
(redirection temporaire, 302 : un retour en `TLS_MODE=none` n'est pas gêné par le cache des
navigateurs).

## Fichiers attendus

Dans `config/certs/` à la racine du repo (contenu **non versionné**, sauf les `.gitkeep`) :

| Fichier | Contenu |
|---|---|
| `config/certs/cert.pem` | Chaîne complète au format PEM : certificat du serveur **en premier**, puis les certificats intermédiaires (la racine est facultative) |
| `config/certs/key.pem` | Clé privée du certificat, au format PEM, **non chiffrée** (Traefik ne gère pas les phrases de passe) |
| `config/certs/ca/ca.pem` | **Facultatif.** Certificat de la CA qui a émis `cert.pem`, au format PEM : CA interne (racine, ou intermédiaire), ou `cert.pem` lui-même s'il est auto-signé. Voir [CA privée](#ca-privée) |

- **Un seul certificat pour toute l'instance.** Il doit couvrir chaque `*_HOSTNAME` de
  `envs/<env>.env` (GitLab, SonarQube, Grafana, Portainer, PlantUML) par son extension
  *subjectAltName* : noms explicites ou joker (`*.devops.exemple.org`). Le CN seul ne suffit pas, les
  navigateurs l'ignorent. Un joker de premier niveau (`*.localhost`, `*.org`) n'est accepté ni par
  OpenSSL ni par les navigateurs. Plusieurs certificats (un par hostname) ne sont pas gérés (#81).
- **Permissions.** `chmod 600 config/certs/key.pem`. Traefik lit les fichiers en tant que `root` dans
  son conteneur, montés en lecture seule.
- **Clé chiffrée.** La déchiffrer une fois, hors du repo, puis déposer le résultat :
  `openssl pkey -in cle-chiffree.pem -out config/certs/key.pem`.

Les fichiers sont montés un à un dans Traefik (`compose/tls/custom.yml`), avec la configuration
dynamique versionnée `config/traefik/tls-custom.yml` qui en fait le certificat par défaut (TLS 1.2
minimum).

## Contrôles au déploiement

`make deploy` et `make check-env` (`scripts/check-env-urls.sh`, fonction `verifier_certificats_custom`
de `scripts/lib/tls.sh`) refusent de continuer, avec un message explicite, si :

- `cert.pem` ou `key.pem` est absent, vide ou illisible ;
- `openssl` est absent de l'hôte (requis pour les contrôles suivants) ;
- `cert.pem` n'est pas un certificat PEM, ou `key.pem` n'est pas une clé PEM, ou la clé est chiffrée ;
- la clé ne correspond pas au certificat ;
- le certificat est expiré ;
- le certificat n'a pas d'extension *subjectAltName* ou ne couvre pas l'un des hostnames ;
- `config/certs/ca/` contient autre chose que `ca.pem` (une clé de CA, un `.srl`…) ;
- `ca.pem` est vide, n'est pas un certificat PEM, contient une clé privée, ou ne permet pas de
  vérifier `cert.pem` (`openssl verify -partial_chain`) ;
- une `*_EXTERNAL_URL` n'est pas en `https://<hostname>`, ou `SONARQUBE_EXTERNAL_URL` /
  `GRAFANA_EXTERNAL_URL` est absente (leur défaut est en `http://`).

Ils **avertissent** sans bloquer si le certificat expire dans moins de 30 jours, si `key.pem` est
lisible par d'autres utilisateurs, ou si `ca.pem` est présent pour une instance qui n'est pas en
`custom` (il y est ignoré).

Sans passer par `make`, `docker compose up` échoue aussi si un fichier manque
(`bind source path does not exist`) : Docker ne crée pas de répertoire vide à sa place.

## Mise en place

1. `make init ENV=<env>` en répondant `custom` à `TLS_MODE` : les URLs publiques sont générées en
   `https://`. Pour un fichier existant, passer `TLS_MODE=custom` et les trois `*_EXTERNAL_URL` en
   `https://` à la main.
2. Déposer `cert.pem` et `key.pem` dans `config/certs/`, puis `chmod 600 config/certs/key.pem`.
   Certificat d'une CA interne ou auto-signé : déposer aussi `config/certs/ca/ca.pem`.
3. `make deploy ENV=<env>`, puis `make bootstrap ENV=<env>`.
4. Contrôler le certificat présenté :
   `openssl s_client -connect <hostname>:443 -servername <hostname> < /dev/null | openssl x509 -noout -subject -enddate -serial`.

## Renouvellement

Traefik lit les certificats à son démarrage : un fichier remplacé n'est pris en compte qu'après la
recréation de son conteneur.

1. **Conserver l'ancienne paire** hors du repo (retour arrière), par exemple
   `cp -p config/certs/cert.pem config/certs/key.pem ~/sauvegarde-certs/`.
2. **Déposer la nouvelle paire** sous les mêmes noms. De préférence, écrire chaque fichier à côté
   puis le renommer (`mv`), pour ne jamais exposer un fichier à moitié copié :
   `cp nouveau-cert.pem config/certs/cert.pem.new && mv config/certs/cert.pem.new config/certs/cert.pem`
   (idem pour `key.pem`, puis `chmod 600 config/certs/key.pem`).
3. **Recharger** : `make reload-certs ENV=<env>`. La cible refait les contrôles de `check-env` : en cas
   d'erreur (clé non appariée, hostname non couvert…), rien n'est redémarré et l'ancien certificat
   reste servi, mais seulement jusqu'au prochain redémarrage de Traefik (redémarrage de l'hôte…) :
   corriger, ou remettre l'ancienne paire, sans attendre. Sinon elle recrée Traefik et attend qu'il soit `healthy`. **Coupure** : tous les
   services web sont indisponibles quelques secondes. Le SSH de GitLab n'est pas concerné.
4. **Vérifier** que le nouveau certificat est servi : commande `openssl s_client` ci-dessus (nouveau
   numéro de série, nouvelle date d'expiration).
5. **Retour arrière** si besoin : remettre l'ancienne paire, puis `make reload-certs ENV=<env>`.

Rien n'est automatisé côté échéance : suivre la date d'expiration, signalée par `make check-env` dans
les 30 jours qui précèdent, et planifier le renouvellement avec la PKI.

## CA privée

Les navigateurs et les postes de l'organisation font en général déjà confiance à la CA interne. Les
conteneurs de la plateforme, non : le runner joint GitLab par son URL publique, donc par Traefik et
son certificat ([GitLab derrière le proxy](gitlab-proxy.md#runner-et-jobs-ci)).

**Fichier** : `config/certs/ca/ca.pem`, facultatif. Il ne contient que des certificats publics (CA
racine, éventuellement intermédiaires) ; le répertoire `config/certs/ca/` n'admet que lui, parce
qu'il est monté dans le runner et copié sur le serveur. Ne jamais y laisser la clé de la CA. Sans ce
fichier (certificat d'une CA publique), rien ne change.

**Mécanisme**, en `TLS_MODE=custom` seulement :

- `compose/tls/gitlab/custom.yml` monte `config/certs/ca/` en lecture seule dans `gitlab-runner`
  (`/etc/devops-platform/ca/`). En `none` et `letsencrypt`, rien n'est monté.
- `make bootstrap` vérifie l'URL publique avec cette CA (`curl --cacert`, jamais `-k`) et enregistre
  le runner avec `--tls-ca-file` : `config.toml` porte `tls-ca-file`, que le runner utilise pour
  `register`, `verify` et la récupération des jobs.
- Les jobs reçoivent la CA dans `CI_SERVER_TLS_CA_FILE`, et le helper l'utilise pour cloner par l'URL
  publique en `https://` (hors hostnames `*.localhost`, clonés par l'entrypoint interne de Traefik :
  [réseau des jobs](gitlab-proxy.md#réseau-des-jobs)).
- En déploiement distant, seul `ca.pem` est copié sur le serveur ([déploiement](deploiement.md)).

**Ajout, retrait ou changement de CA** : `make deploy ENV=<env>`, puis `make bootstrap ENV=<env>`. Le
bootstrap ré-enregistre le runner si la présence de la CA a changé. Si seul le contenu de `ca.pem`
change (même chemin), le runner garde la CA chargée à son démarrage : le redémarrer
(`scripts/instance.sh compose <env> restart gitlab-runner`, jobs en cours interrompus).
`make reload-certs` ne recrée que Traefik.

**Clients non couverts** :

- **Outils lancés depuis l'hôte** (`curl`, `git`…) : ajouter la CA au magasin de
  l'hôte (Debian/Ubuntu : copier `ca.crt` dans `/usr/local/share/ca-certificates/`, puis
  `update-ca-certificates`), ou passer `CURL_CA_BUNDLE=/chemin/ca.pem` dans l'environnement.
- **Appels de SonarQube vers GitLab** (JVM) : ils ne connaissent pas la CA interne (#110).
- **Jobs** : seuls git et `CI_SERVER_TLS_CA_FILE` sont fournis ; un outil qui appelle l'API GitLab
  depuis un job doit recevoir la CA explicitement (`curl --cacert "$CI_SERVER_TLS_CA_FILE"`).
