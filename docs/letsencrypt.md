# Certificats Let's Encrypt (`TLS_MODE=letsencrypt`)

Avec `TLS_MODE=letsencrypt`, Traefik sert la plateforme en HTTPS (port 443) avec des certificats
[Let's Encrypt](https://letsencrypt.org/) qu'il obtient et renouvelle lui-même (protocole ACME,
resolver `letsencrypt`) : un certificat par hostname, demandé dès que Traefik détecte le service,
puis renouvelé automatiquement 30 jours avant son échéance. Le port 80 redirige vers HTTPS (redirection
temporaire, comme en `custom` : un retour en `TLS_MODE=none` n'est pas gêné par le cache des
navigateurs).

Configuration : `compose/tls/letsencrypt.yml` (overlay de `compose/proxy.yml`) et
`config/traefik/acme-<challenge>.env`.

## Prérequis

- **Serveur joignable depuis Internet**, avec un **nom public** par service : chaque `*_HOSTNAME`
  (GitLab, SonarQube, Grafana, Portainer, PlantUML) doit résoudre (DNS, enregistrement A/AAAA) vers
  le serveur. Let's Encrypt ne délivre pas de certificat pour `localhost`, `*.localhost` ni une
  adresse IP : `make deploy` les refuse (en local, rester en `TLS_MODE=none`).
- **Port ouvert** selon le challenge (pare-feu, groupe de sécurité, redirection NAT) :

  | `ACME_CHALLENGE` | Challenge | Port interrogé par Let's Encrypt |
  |---|---|---|
  | `http` (défaut) | HTTP-01 | 80 |
  | `tls` | TLS-ALPN-01 | 443 (le port 80 peut rester fermé en amont) |

  Le challenge DNS-01 (certificats joker, serveur non joignable depuis Internet) n'est pas géré (#75).
- **Email du compte ACME** (`ACME_EMAIL`, obligatoire) : adresse réelle de l'opérateur. Let's Encrypt
  refuse les domaines d'exemple (`example.com`…).

## Mise en place

1. `make init ENV=<env>` en répondant `letsencrypt` à `TLS_MODE` (défaut pour un domaine non local) :
   l'email ACME est demandé et les URLs publiques sont générées en `https://`. Pour un fichier
   existant : `TLS_MODE=letsencrypt`, `ACME_EMAIL=…` et les trois `*_EXTERNAL_URL` en `https://`.
2. Facultatif : `ACME_CHALLENGE=tls`, ou `ACME_CA_SERVER` pointant vers l'environnement de
   **staging** pour un premier essai sans consommer les
   [limites de production](https://letsencrypt.org/docs/rate-limits/)
   (`https://acme-staging-v02.api.letsencrypt.org/directory`, certificats non reconnus par les
   navigateurs).
3. `make deploy ENV=<env>`.
4. Contrôler le certificat présenté (émetteur Let's Encrypt, échéance) :
   `openssl s_client -connect <hostname>:443 -servername <hostname> < /dev/null | openssl x509 -noout -issuer -enddate`.
   En cas d'échec, Traefik sert son certificat auto-signé par défaut (`TRAEFIK DEFAULT CERT`) : la
   cause est dans ses logs (`docker compose --env-file envs/<env>.env logs traefik | grep -i acme`, ou
   Grafana) — DNS, port fermé, limite atteinte.

## Contrôles au déploiement

`make deploy` et `make check-env` (`scripts/check-env-urls.sh`, fonction `verifier_letsencrypt` de
`scripts/lib/tls.sh`) refusent de continuer, avec un message explicite, si :

- `ACME_EMAIL` est absent ou mal formé ;
- `ACME_CHALLENGE` n'est ni `http` ni `tls` (vide : `http`) ;
- un hostname est local (`localhost`, `*.localhost`) ou une adresse IP, y compris par défaut
  (`*_HOSTNAME` absent vaut `<service>.localhost`) ;
- une `*_EXTERNAL_URL` n'est pas en `https://<hostname>`, ou `SONARQUBE_EXTERNAL_URL` /
  `GRAFANA_EXTERNAL_URL` est absente (leur défaut est en `http://`).

Ils **avertissent** sans bloquer si `ACME_EMAIL` est sur un domaine d'exemple. La résolution DNS et
l'ouverture des ports ne sont pas contrôlées.

## Stockage et renouvellement

Le compte ACME et les certificats sont conservés dans `acme.json` (permissions `600`), sur le volume
**`devops-platform_traefik_acme`** : ils survivent aux redéploiements et à la recréation de Traefik,
qui ne redemande donc pas les certificats à chaque démarrage. Le renouvellement est automatique,
sans coupure ni action de l'opérateur.

- **Sauvegarde** : ce volume contient la clé du compte ACME et les clés privées des certificats ; le
  sauvegarder comme un secret. Perdu, il est simplement reconstitué (nouveau compte, nouveaux
  certificats), dans la limite des quotas de Let's Encrypt.
- **Staging → production** : Traefik ne lie pas `acme.json` à l'annuaire ACME. Après un essai en
  staging, retirer `ACME_CA_SERVER`, puis vider le stockage avant de redéployer, sinon les certificats
  de staging restent servis jusqu'à leur renouvellement (#74) :
  `docker compose --env-file envs/<env>.env rm -sf traefik && docker volume rm devops-platform_traefik_acme && make deploy ENV=<env>`.
- **Changement de mode** : en repassant en `none` ou `custom`, le volume est conservé, inutilisé.
  Piloter toujours la plateforme avec `--env-file` (ou `make`) : sans lui, `TLS_MODE` vaut `none` et un
  `docker compose up` retirerait le HTTPS de Traefik.
