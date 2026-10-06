"""Code d'exemple analysé par le smoke test (make smoke) : son contenu importe peu."""


def moyenne(valeurs):
    """Moyenne d'une liste de nombres, None si la liste est vide."""
    if not valeurs:
        return None
    return sum(valeurs) / len(valeurs)


if __name__ == "__main__":
    print(moyenne([1, 2, 3]))
