// Relais SSO de SonarQube (service sonarqube-sso, compose/sonarqube.yml) : fonctions njs appelées par
// nginx.conf pour chaque requête de l'interface web, après la passerelle d'authentification.
// Mécanisme et limites : docs/sso.md, « SonarQube ».
//
// SonarQube (SSO par en-têtes, sonar.web.sso.*) synchronise les groupes de l'utilisateur sur la liste
// de l'en-tête X-Auth-Request-Groups : il l'ajoute aux groupes SonarQube de même nom et le retire des
// autres. L'en-tête reçu de la passerelle (chemins complets des groupes GitLab) est réécrit :
//   - noms réservés de SonarQube retirés (un groupe GitLab nommé « sonar-administrators » ne donne
//     pas l'administration) ;
//   - sonar-users toujours présent : l'en-tête n'est jamais vide, la synchronisation a toujours lieu
//     (un utilisateur retiré de tous ses groupes GitLab perd aussi ses groupes SonarQube) ;
//   - sonar-administrators ajouté pour les membres de SSO_GROUPE_ADMIN (chemin complet, comparaison
//     exacte insensible à la casse ; membres hérités d'un groupe parent compris, comme dans la liste
//     de GitLab ; vide : personne).

// Groupes propres à SonarQube, jamais repris de GitLab (comparaison insensible à la casse)
var GROUPES_RESERVES = ['sonar-administrators', 'sonar-users'];

// Comptes locaux de la plateforme : SonarQube associerait l'utilisateur GitLab de même login au compte
// local (même fournisseur d'identité), ces logins sont donc refusés. À garder identique au compte admin
// et à SONAR_ANALYSE_LOGIN de scripts/lib/sonarqube.sh.
var COMPTES_LOCAUX = ['admin', 'devops-platform-analyse'];

function groupesSonar(entete, groupeAdmin) {
    var admin = (groupeAdmin || '').trim().toLowerCase();
    var resultat = [];
    var minuscules = [];
    var estAdmin = false;
    (entete || '').split(',').forEach(function (brut) {
        var groupe = brut.trim();
        var cle = groupe.toLowerCase();
        if (groupe === '') {
            return;
        }
        if (admin !== '' && cle === admin) {
            estAdmin = true;
        }
        if (GROUPES_RESERVES.indexOf(cle) === -1 && minuscules.indexOf(cle) === -1) {
            resultat.push(groupe);
            minuscules.push(cle);
        }
    });
    resultat.push('sonar-users');
    if (estAdmin) {
        resultat.push('sonar-administrators');
    }
    return resultat.join(',');
}

function loginRefuse(login) {
    var l = (login || '').trim().toLowerCase();
    return l === '' || COMPTES_LOCAUX.indexOf(l) !== -1;
}

// $sso_groupes : valeur de X-Auth-Request-Groups transmise à SonarQube
function groupes(r) {
    return groupesSonar(r.headersIn['X-Auth-Request-Groups'], process.env.SSO_GROUPE_ADMIN);
}

// $sso_refus : « 1 » si la requête doit être refusée (login absent ou compte local de la plateforme)
function refus(r) {
    return loginRefuse(r.headersIn['X-Auth-Request-User']) ? '1' : '';
}

export default { groupes: groupes, refus: refus, groupesSonar: groupesSonar, loginRefuse: loginRefuse };
