import gbotlib as gbl

SEND_PROP, DELTA_PROP, HOLD_PROP = 0.425, 0.300, 0.200


def bot(galaxy):
    if galaxy.state == "play":
        planets = gbl.categorize(galaxy, "planets")
        if len(planets["enemy"]) == 0:
            return
        targets = sorted(
            planets["enemy"], key=lambda p: p.production / (p.ships + 1), reverse=True
        )
        for planet in planets["ally"]:
            i, s = 0, planet.ships
            while s >= HOLD_PROP * planet.production:
                gbl.send(
                    f"/SEND {round(SEND_PROP * 100)} {planet.n} {targets[i % len(targets)].n}"
                )
                i, s = i + 1, s * DELTA_PROP


if __name__ == "__main__":
    gbl.run(bot)
