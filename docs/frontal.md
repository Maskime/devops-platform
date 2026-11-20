# Instance derrière un frontal d'hôte (`EXPOSITION=frontal`)

Par défaut (`EXPOSITION=directe`), le proxy de la plateforme (Traefik) publie lui-même les ports 80 et
443 de l'hôte. Avec `EXPOSITION=frontal`, ces ports appartiennent à un **frontal** : un reverse proxy
propre à l'hôte, indépendant de l'instance, qui répartit le trafic web par nom de domaine entre
l'instance et les **services voisins** (vocabulaire : [glossaire](../GLOSSARY.md)). La plateforme ne
route pas les services voisins et ne dépend pas du frontal pour son trafic interne.

```text
Internet ──80/443──▶ frontal (hôte) ──TCP passthrough + PROXY v2──▶ Traefik :443 ──▶ GitLab, SonarQube…
                        │ réseau devops-platform_frontal
                        └──▶ services voisins
runner, jobs CI, projets co-localisés ──alias réseau──▶ Traefik :443 (sans frontal)
```

Le repo ne fournit pas de frontal : l'opérateur l'installe et l'exploite à part (exemple de référence
ci-dessous).

## Configuration de l'instance

Dans `envs/<env>.env` (détail des variables : `envs/.env.example`) :

```dotenv
EXPOSITION=frontal
FRONTAL_SUBNET=172.31.253.0/29
FRONTAL_IP=172.31.253.2
FRONTAL_IP_TRAEFIK=172.31.253.3
TLS_MODE=letsencrypt
ACME_CHALLENGE=tls
```

| Variable | Rôle |
|---|---|
| `EXPOSITION` | `directe` (défaut) ou `frontal` |
| `FRONTAL_SUBNET` | Sous-réseau du réseau `devops-platform_frontal`, qui relie le frontal à Traefik |
| `FRONTAL_IP` | Adresse du frontal sur ce réseau : seule source dont Traefik honore l'en-tête PROXY protocol |
| `FRONTAL_IP_TRAEFIK` | Adresse fixe de Traefik sur ce réseau, cible du frontal (port 443) |

L'adresse de Traefik est fixe : Docker ne sait pas réserver une adresse pour un conteneur tiers, et une
adresse dynamique pourrait, à une recréation de Traefik pendant un arrêt du frontal, tomber sur
`FRONTAL_IP`.

`make check-env` (donc `make deploy`) refuse, en indiquant la ligne à corriger :

- une `EXPOSITION` autre que `directe` ou `frontal` ;
- en frontal, `TLS_MODE=none`, et `TLS_MODE=letsencrypt` sans `ACME_CHALLENGE=tls`. Le port 80
  appartient au frontal : seul le challenge TLS-ALPN-01, qui passe par le 443 en passthrough, aboutit à
  Traefik. `TLS_MODE=custom` est admis ;
- une variable du frontal absente ;
- un `FRONTAL_SUBNET` mal formé (CIDR IPv4, /16 à /29) ou qui chevauche `GITLAB_PROXY_SUBNET` ou
  `GRAFANA_PROXY_SUBNET` ;
- une adresse hors du sous-réseau, égale à l'adresse réseau, au broadcast ou à la première adresse
  (passerelle Docker), ou deux adresses identiques.

Le chevauchement avec les autres réseaux Docker de l'hôte n'est pas contrôlé : Docker refuse alors de
créer le réseau (« Pool overlaps »).

## Ce que fait la plateforme en frontal

Overlay `compose/exposition/frontal.yml`, fusionné après `compose/proxy.yml` et `compose/tls/<mode>.yml` :

- **Aucun port web publié** : seul reste publié le SSH de GitLab (`GITLAB_SSH_PORT`). `make verify`
  le contrôle pour chaque mode d'exposition ([surface d'exposition](exposition.md#surface-dexposition)).
- **Réseau `devops-platform_frontal`**, créé par `make deploy` avec `FRONTAL_SUBNET`, interne (sans
  passerelle sortante). Traefik y est rattaché à `FRONTAL_IP_TRAEFIK`.
- **HTTPS seul** : l'entrypoint `web` (:80) n'écoute que sur la boucle locale du conteneur Traefik,
  injoignable depuis tout réseau, frontal compris. Compose ne permet pas de retirer la variable qui le
  définit.
- **PROXY protocol** sur l'entrypoint `websecure` (:443), avec `proxyProtocol.trustedIPs=FRONTAL_IP` :
  l'IP réelle du client, transmise par le frontal, apparaît dans les logs d'accès de Traefik et, par
  `X-Forwarded-For`, dans GitLab.
- **Réseaux internes inchangés** (`platform`, `ci`, `consumers`) : le runner, les jobs CI et les projets
  co-localisés joignent toujours Traefik par les alias réseau, en HTTPS, sans passer par le frontal. En
  frontal, ils doivent utiliser `https://` : une URL en `http://` aboutit à un refus de connexion (et
  non plus à une redirection).

## Contrat attendu du frontal

1. **Rejoindre le réseau** `devops-platform_frontal` (réseau externe) à l'adresse `FRONTAL_IP`. Il est
   interne : le frontal publie ses ports 80 et 443 par un autre réseau, le sien.
2. **Router en TCP, en passthrough TLS**, les connexions dont le SNI est un hostname de l'instance, vers
   `FRONTAL_IP_TRAEFIK:443`. Le TLS est terminé par Traefik : certificats Let's Encrypt ou fournis,
   comme en directe. La règle porte sur le domaine parent des hostnames de l'instance, ou sur leur liste
   s'ils n'ont pas de parent commun. Les hostnames de l'instance sont tous les `*_HOSTNAME` (accueil,
   GitLab, SonarQube, serveur MCP SonarQube, Grafana, Portainer, PlantUML).
3. **Envoyer le PROXY protocol v2** sur ces connexions.
4. **Prendre en charge le port 80** et la redirection vers HTTPS : la plateforme n'écoute plus en HTTP.
5. **Refuser les SNI inconnus** : aucune connexion vers un nom qui n'est ni un service voisin, ni un
   hostname de l'instance.
6. **Ordre de démarrage** : le réseau `devops-platform_frontal` n'existe qu'après le premier
   `make deploy` de l'instance. Démarrer le frontal ensuite, ou créer son rattachement après coup.
   `make down` laisse le réseau en place tant que le frontal y est rattaché (« Resource is still in
   use », sans erreur).
7. **Ne rattacher que le frontal à ce réseau** : aucun service voisin. Voir les limites ci-dessous.

## Configuration de référence (Traefik v3)

Frontal Traefik v3 (testé avec `traefik:v3.7.13`) devant une instance aux hostnames
`*.devops.mondomaine.fr`. Compose du frontal :

```yaml
services:
  frontal:
    image: traefik:v3.7.13
    restart: unless-stopped
    command:
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --providers.file.filename=/etc/traefik/dynamique.yml
      # + providers et resolver ACME propres aux services voisins
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./dynamique.yml:/etc/traefik/dynamique.yml:ro
    networks:
      default: {}
      devops-platform:
        ipv4_address: 172.31.253.2   # FRONTAL_IP

networks:
  devops-platform:
    external: true
    name: devops-platform_frontal
```

Configuration dynamique (`dynamique.yml`) :

```yaml
tcp:
  routers:
    devops-platform:
      entryPoints: [websecure]
      # Domaine parent des hostnames de l'instance. Sans parent commun :
      # HostSNI(`gitlab.a.fr`) || HostSNI(`sonarqube.b.fr`) || …
      rule: HostSNIRegexp(`^.+\.devops\.mondomaine\.fr$`)
      tls:
        passthrough: true
      service: devops-platform
  services:
    devops-platform:
      loadBalancer:
        serversTransport: proxy-protocol-v2
        servers:
          - address: 172.31.253.3:443   # FRONTAL_IP_TRAEFIK
  serversTransports:
    proxy-protocol-v2:
      proxyProtocol:
        version: 2
tls:
  options:
    default:
      # SNI inconnu : poignée de main TLS refusée (les routeurs en passthrough ne sont pas concernés)
      sniStrict: true
```

Contrôle depuis un poste : `curl -sI https://gitlab.devops.mondomaine.fr/users/sign_in` doit répondre,
et `scripts/instance.sh compose <env> logs traefik` doit montrer l'IP publique du poste, pas
`FRONTAL_IP`. `make smoke ENV=<env>` vérifie le contrat de bout en bout :
- présence du frontal ;
- chaque hostname servi par le frontal ;
- PROXY protocol ;
- aucun port web publié.

Il signale aussi un frontal absent ou défaillant, distinct d'une plateforme en panne
([smoke test](smoke-test.md#instance-derrière-un-frontal)).

## Passer de `directe` à `frontal`

1. Renseigner les variables ci-dessus. En `letsencrypt`, passer `ACME_CHALLENGE=tls`.
2. `make deploy ENV=<env>` : Traefik est recréé sans ports publiés et rattaché au nouveau réseau. Les
   certificats Let's Encrypt du volume `devops-platform_traefik_acme` sont conservés ; ceux de
   `config/certs/` (`custom`) ne changent pas.
3. Démarrer le frontal : 80 et 443 de l'hôte sont libres depuis l'étape 2. Le service est interrompu
   entre les deux étapes.

Retour en `directe` : `EXPOSITION=directe` (ou ligne commentée), arrêter le frontal (il libère 80 et
443), puis `make deploy`.

**Changer `FRONTAL_SUBNET`** après création : Compose ne recrée pas un réseau existant. Arrêter le
frontal (ou le détacher du réseau), `scripts/instance.sh compose <env> stop traefik`,
`docker network rm devops-platform_frontal` (sur l'hôte de l'instance), puis `make deploy` et
redémarrer le frontal avec la nouvelle `FRONTAL_IP`.

## Limites

- **PROXY protocol non exigé.** Traefik honore l'en-tête PROXY de la seule `FRONTAL_IP` et ignore celui
  de toute autre adresse : l'IP réelle ne peut pas être usurpée. Il ne refuse pas pour autant une
  connexion sans en-tête, de quelque adresse qu'elle vienne. C'est nécessaire au runner, aux jobs et aux
  projets co-localisés, qui joignent le même entrypoint par les alias, sans en-tête. Un frontal mal
  configuré, sans PROXY protocol, fonctionne donc, mais les logs montrent alors `FRONTAL_IP` au lieu
  de l'IP des clients. `make smoke` le détecte ; il vérifie aussi qu'un en-tête forgé depuis une autre
  adresse est ignoré. Aucun port n'étant publié, l'extérieur n'atteint la plateforme que par le frontal.
- **Entrypoints internes joignables depuis le réseau du frontal.** Traefik écoute sur toutes ses
  interfaces : `interne` (:8000, HTTP clair, routeurs des jobs CI vers GitLab et SonarQube) et
  `traefik` (:8080, sonde de santé) sont joignables depuis `devops-platform_frontal`. D'où la règle 7
  du contrat : n'y rattacher que le frontal.
- **Hostnames sans domaine parent commun** : règle `HostSNI` en liste, à tenir à jour à chaque
  changement de hostname.
- **Pas de frontal fourni** par le repo : ni installation, ni supervision, ni contrôle de sa
  configuration par `make`.
