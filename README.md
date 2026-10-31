# Choo-choo Charles Coop Mod

Online co-op for **Choo-Choo Charles** (Steam, game version 1.2.0, Unreal Engine 4.26).
One player hosts their own save and friends join it. Everyone walks around the island,
rides and drives the train, shares pickups, and respawns on the train after dying.

This is a [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod. It contains no game
files.

## Play

Everyone needs their own copy of the game.

1. Download `CharlesCoop-<version>.zip` from [Releases](../../releases) and unzip it anywhere.
2. Double-click **Install.bat**. It finds the game in your Steam library, downloads
   RE-UE4SS v3.0.1 from its official GitHub release (checked by SHA-256), and adds the mod.
   **Uninstall.bat** removes everything again.
3. The host double-clicks **Host.bat**. A few seconds after the main menu shows, the game
   opens the host's save for friends. Pick up the train key in single player first:
   before that, the train levers don't work for anyone.
4. Friends double-click **Join.bat** and enter the host's address. The game connects by
   itself. About a minute after loading in they get their character, standing on the
   host's train. Their own save is backed up first, because the game autosaves the
   host's world into the joining player's save slot.
5. **Solo.bat** switches back to normal single player and offers to restore your own save.

The host needs UDP port 7777 reachable. The easiest way is a free VPN that everyone joins
(Tailscale, ZeroTier, Radmin VPN). Otherwise forward UDP 7777 on the host's router.

**After dying, don't press the death-screen buttons.** The mod closes the screen by itself
and respawns you on the train after 5 seconds. The game's own "Retry" and "Respawn at
train" reload the world, which would end the session for everyone.

## Status

Tested with two copies of the game on one PC (`test/run_pair.ps1`, scenario `coop`):

| Feature | State |
|---|---|
| Join the host's world, get control | works |
| See each other (villager bodies) | works |
| New players are put on the train | works |
| Ride the train together, anyone drives (middle lever: go, third lever: brake) | works |
| Shared pickups: anyone picks up -> everyone gets it, gone for everyone | works (scraps and quest items, both directions) |
| Respawn on the train without reloading, death screen closes by itself | works (host and guest, repeated deaths) |
| Damage goes to the player who was hit | works; see the known issues |
| Charles / cultists chasing guests | untested |
| Guns, upgrades, story events (quests, cutscenes) shared | not done |
| Two different PCs over the internet | untested |

Latest `coop` run (2026-10-31): host and guest each pick up an item and the other side
gets it too. The guest dies on its own machine twice and once from damage on the host.
The host dies twice. Every death gave exactly one respawn on the train, and both players
were alive and in sight of each other at the end.

### Known issues

- The game has one health bar, "player 0's". Damage to any character lowers it, so a
  lethal hit on a friend's character can make the host die for a moment. The mod spots
  that "false death" and puts the host back on the same spot with their health bar
  restored, after about 1.5 s.
- The train can flicker for a moment where one track joins the next.
- What the first train lever does in co-op is unknown.
- One test run had a guest crash about 25 s after joining (access violation, not
  reproduced in the 8 runs after it).

## How it works

- **Networking:** the game's own Unreal networking. The host runs `open <map>?listen`, the
  guest runs `open <address>`. The Steam net driver is swapped for the IP one.
- **Messages:** host -> guest via `PlayerController:ClientMessage("COOP|...")`; guest ->
  host via `ServerExecRPC("COOP|...")` caught with a hook on the host.
- **Train** (`train.lua`, `sync.lua`): the host simulates the train and streams its
  state at 10 Hz. A guest's lever clicks are sent to the host and replayed there.
- **Bodies** (`avatar.lua`, `players.lua`): the player character has no visible body, so
  other players get a villager mesh. Movement uses client-authoritative positions.
- **Pickups** (`progress.lua`): `ItemPickup_C:Interact` saves `<ItemID> = count` and
  `<ItemID>-<PickupName> = Collected`, then destroys the pickup. The mod sends
  `pickup|<name>|<id>`, and the other machines run the same `Interact` on their copy. If
  the host doesn't have that pickup loaded, it adds the item with `Gather Item` directly.
- **Respawn** (`respawn.lua`): a death is noticed when the death screen opens, found
  through a hook on `DeathScreen_C:Construct` (the game's "Death call" event only fires
  for the first character of a session). The host destroys the dying character, then
  runs `GameMode:RestartPlayer` and puts the new character on the train's respawn point.
  If a controller loses its character without a death, the mod re-possesses it.
- **Damage** (`respawn.lua`): characters you don't control get the game's own "Cancel
  Fall Damage on Reset" flag every 100 ms, so their falls don't hurt you. For other hits
  on them, your health bar is put back and the host sends the hit to its owner.

Things learned the hard way:

- UE4SS 3.0.1 runs Lua hooks on Blueprint functions *after* the function, so parameters
  can't be changed before the call.
- `FindAllOf` walks every object in the game. Three of them every 100 ms starved the
  host's game thread until guest messages arrived 22 s late.

## Develop and test

- `mod/CharlesCoop/Scripts/`: the mod. `main.lua` holds the role and phase logic and
  the scripted test scenarios (env `COOP_TEST`).
- `installer/`: Install / Host / Join / Solo / Uninstall scripts for players.
- `tools/build_release.ps1`: builds `dist/CharlesCoop-<version>.zip`.
- `tools/check_lua.py`: Lua syntax check (run before every test).
- `test/run_pair.ps1`: starts a host and a guest on one PC, on a **copy** of the game
  with UE4SS installed. Each instance gets its own `-userdir`, so your real saves are
  never touched; the script checks that. Example:

  ```
  powershell -ExecutionPolicy Bypass -File test\run_pair.ps1 -GameCopy "<copy of game dir>" -Test coop -Seed "<copy of a save folder>"
  ```

  `-Seed` copies `.sav` files into both instances. The train levers need a save where
  the train key has been picked up. Logs and in-game screenshots go to `runs/`.

## Credits

- [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) for the Lua scripting runtime.
- Choo-Choo Charles is by Two Star Games. This project is not affiliated with them.
- Built with the [coop-anything](https://github.com/cranebeaker/coop-anything) playbook.
