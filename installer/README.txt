CharlesCoop 0.2.0 - online co-op for Choo-Choo Charles (Steam, game version 1.2.0)
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
            menu. About a minute after loading in you get your character, standing on
            the host's train. Your own save is backed up first, because the game
            autosaves the host's world into your save slot.
  Solo.bat  Normal single player. Offers to restore your own save from before co-op.

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

Known issues:
  - the game has one health bar for "player 0". A lethal hit on a friend's character can
    make the host die for a moment; the host is put back on the spot at once
  - Charles and the cultists run on the host and go after the host; whether they chase
    friends too is untested
  - guns, upgrades and the story (quests, cutscenes) are not shared yet
  - the train can flicker for a moment where one track joins the next
  - not yet tested between two different PCs over the internet
  - what the first lever does in co-op is unknown
