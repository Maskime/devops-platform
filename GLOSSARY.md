# Glossaire

Vocabulaire du domaine de la plateforme DevOps.

## Exposition

**Frontal** :
Reverse proxy propre à l'hôte, indépendant de toute instance, qui reçoit tout le trafic web entrant et le
répartit par nom de domaine entre l'instance et les services voisins.
_À éviter_ : proxy, Traefik (ambigus avec le proxy de la plateforme)

**Proxy de la plateforme** :
Point d'entrée web d'une instance, qui route vers ses services (GitLab, SonarQube, Grafana…) et applique
son authentification unique. Il reçoit le trafic directement, ou par le frontal quand l'hôte en a un.

**Service voisin** :
Application hébergée sur le même hôte qu'une instance et exposée par le même frontal, sans lien avec la
plateforme pour son exposition.
_À éviter_ : projet co-localisé (qui désigne un consommateur de la plateforme)

**Projet co-localisé** :
Projet dont les conteneurs tournent sur le même hôte qu'une instance et consomment ses services (GitLab,
SonarQube) par le réseau des consommateurs.

**Projet hébergé** :
Projet dont le dépôt vit dans le GitLab d'une instance et dont les pipelines tournent sur son runner.

Un même projet peut cumuler les rôles : pocket-money, par exemple, est un projet hébergé sur l'instance
et un service voisin exposé par le frontal.
