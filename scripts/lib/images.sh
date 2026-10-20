#!/usr/bin/env bash
# Images utilitaires lancées par les scripts (docker run), partagées par scripts/instance.sh (copie et
# nettoyage des fichiers de config sur l'hôte cible) et scripts/smoke.sh (sentinelles de l'isolation des
# projets co-localisés). Montée de version : docs/montee-de-version.md.
# Fichier à sourcer : ne modifie pas les options du shell appelant.

# Dernière stable, tag figé par son digest
# shellcheck disable=SC2034 # lue par les scripts qui sourcent ce fichier
readonly BUSYBOX_IMAGE="busybox:1.38.0@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e"
