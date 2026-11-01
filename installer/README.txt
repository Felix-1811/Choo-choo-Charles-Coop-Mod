CharlesCoop 0.4.0 - online co-op for Choo-Choo Charles (Steam, game version 1.2.0)
====================================================================================

Everyone who plays needs their own copy of the game and these files.

Install (once, everyone): double-click Install.bat
  - finds the game in your Steam library
  - downloads RE-UE4SS v3.0.1 from its official GitHub release (checked by SHA-256)
  - adds the CharlesCoop mod. Uninstall.bat removes it all again.

Play:
  Host.bat  The host. A few seconds after the main menu appears, the game opens YOUR
            saved game for your friends. Pick up the train key in single player first:
            before that, the train levers do not work for anyone.
  Join.bat  A friend. Enter the host's address; the game connects by itself at the main
            menu. It loads the host's story and the world once more, then you stand on
            the host's train (about a minute in all). Your own save is kept safe first,
            and only your settings stay in the slot while you play co-op.
  Solo.bat  Normal single player. Puts your own save back by itself; the co-op state is
            kept beside it.

Connecting over the internet: the host needs UDP port 7777 reachable. The easiest way is
a free VPN that everyone joins (Tailscale, ZeroTier, Radmin VPN); then use the host's VPN
address. Otherwise forward UDP 7777 on the host's router and use the host's public IP.

What works (tested with two copies of the game on one PC):
  - joining the host's world; new players are put on the train
  - seeing each other as villager characters
  - riding the train together; anyone can drive it (middle lever: go, third lever: brake)
  - shared pickups: when anyone picks up scraps or an item, everyone gets it, and it is
    gone for everyone. The host's save is the one that keeps it.
  - respawning: when someone dies, the death screen closes by itself and after 5 seconds
    they get a new character on the train. Do not wait for the buttons: the game's own
    "Retry" / "Respawn at train" reload the world and would end the session.
  - damage goes to the player who was hit
  - Charles and the cultists go after whoever is nearest. Charles only wakes up once the
    train moves. If he catches a friend on foot, that friend respawns on the train and
    he leaves them alone for 20 seconds
  - cultists killed by anyone are dead for everyone
  - the story is shared: missions, doors, chests, mission objects and track switches. What
    one player does counts for everyone, and it stays in the host's save. A friend joining
    late gets the story so far
  - the ending: summoning Charles, the boss fight and the final cutscene play for everyone
  - the train gun: anyone can use it, and a friend's hits damage Charles and the cultists
    for real. Everyone sees where the gun points, and its flash when it fires

Known issues:
  - the game has one health bar for "player 0". A lethal hit on a friend's character can
    make the host die for a moment; the host is put back on the spot at once
  - the story has been tested by test bots, not yet played start to finish by people
  - a bought upgrade is saved for everyone, but only takes effect for the others after
    they load the game again
  - weather and scrap crates can differ between players until a friend joins again
  - you hear nothing when a friend fires the gun (no sound yet, only the flash)
  - no on-screen message yet when a friend starts or finishes a mission
  - the game crashed now and then in testing (more often in long gun tests); it is
    being worked on
  - the train can flicker for a moment where one track joins the next
  - not yet tested between two different PCs over the internet
  - what the first lever does in co-op is unknown
