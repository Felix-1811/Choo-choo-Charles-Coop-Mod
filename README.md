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
   itself. About 15 seconds after loading in they get their character, standing on the
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
| Cultists hunt and shoot whichever player is nearest | works (hits reach the guest, who can die and respawn) |
| Charles hunts a guest who is off the train | works; the mod does the catch itself (see known issues) |
| Charles seen by guests | works (streamed from the host at 10 Hz) |
| Guest uses a train gun, hits damage the real Charles / cultists | works in a bot test (machine gun) |
| Everyone sees where the train gun points | works (sent at 2 Hz, smoothed) |
| Cultists killed by anyone are dead for everyone (also for late joiners) | works |
| Guest gets their character ~15 s after loading in; rejoins after a dropped connection | works (rejoin: code path only, not forced in a test) |
| Host sees the guest's gun fire (muzzle flash, sound) | not done |
| Story: missions, doors, chests, mission objects, track switches shared; late joiners get the story | bot tests: 161 of 161 clicks replayed, no crash (run 181252) |
| Summon, boss fight start, final cutscene on every machine | bot test with a hand-made save, Charles killed by a test hit (run 175716). Credits not reached in a test |
| Upgrades take effect live for the other players | not done (saved for everyone, applied on next load) |
| Whole story played start to finish by people | not done |
| Two different PCs over the internet | untested |

Latest `coop` run (2026-10-31): host and guest each pick up an item and the other side
gets it too. The guest dies on its own machine twice and once from damage on the host.
The host dies twice. Every death gave exactly one respawn on the train, and both players
were alive and in sight of each other at the end.

Latest `enemies` run (2026-10-31): the train wakes Charles, the guest is dropped next
to him, and he switches to the guest and goes for them. The mod catches the guest at 781
units: the guest dies and respawns on the train, while the host stays alive. A cultist
aimed at the host switches to the nearer guest by itself. `guns` run: a machine-gun hit
from the guest's copy of the gun (2.07 on Charles's legs) was applied to the host's Charles.

### Known issues

- Weather and scrap crates roll separately on each machine; a joining guest starts from the host's values, but they can differ afterwards.
- A friend's gun fire shows as effects only, with no sound.
- No on-screen message when a friend starts or finishes a mission.

- The game has one health bar, "player 0's". Damage to any character lowers it, so a
  lethal hit on a friend's character can make the host die for a moment. The mod spots
  that "false death" and puts the host back on the same spot with their health bar
  restored, after about 1.5 s.
- The train can flicker for a moment where one track joins the next.
- What the first train lever does in co-op is unknown.
- Charles's own catch always takes the host (player 0), and the guest's game crashed
  every time the game did it in testing. So when Charles hunts a guest on foot, the mod
  catches the guest itself when he gets within 1000 units: the guest dies and respawns
  on the train, and he leaves that guest alone for 20 s.
- Charles stays asleep until the train moves (as in single player).
- Guests crashed now and then in testing (access violation): once ~25 s after joining,
  once on a character the engine had dropped and re-created when players were far apart
  (fixed: player characters now stay relevant at any distance), and once on startup
  before the mod did anything. The host crashed once during a Charles chase (cause
  unknown).

Latest batch (2026-10-31, 0.3.1): `coop`, `enemies`, `guns` and a normal-mode join, each
with a host and a guest: no crash on either side. Every death gave exactly one respawn.
Charles caught the guest twice, and the guest was on the train 12 s after loading in.

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
- **Enemies** (`enemies.lua`): the AI only runs on the host and reads blackboard keys.
  Every 3 s each enemy's `Player Ref` goes to the nearest living player; hunting cultists
  and Charles (10 Hz) also get the blackboard key `Actor Ref`, and Charles gets
  `Is Player In Train?` and `Sensed Actor Location` too. The engine sent Charles's
  movement to guests only while he stood still, so the host streams him and the guest's
  copy is a puppet with its own tick, movement and damage boxes off.
- **Guns** (`enemies.lua`, `sync.lua`): a guest's gun works on its own copy of the train.
  Every `Damage` on a guest's copy of Charles or a cultist is sent to the host, which
  applies it to the real one with the same hit component. Guest clicks on gun mounts are
  not replayed on the host (it would put the host in the gun seat); levers and gun
  equippers are.
- **Scheduler** (`sched.lua`): every periodic job runs from a hook on the train's
  `ReceiveTick`, on the game thread, instead of separate `LoopAsync` -> `ExecuteInGameThread`
  loops. Crashes inside UE4SS grew with each such loop. When the world changes, every module
  drops its cached game objects.
- **Gun aim** (`turret.lua`): whoever sits at the gun sends its rotation at 2 Hz; the
  other machines ease their copy of the gun toward it.
- **Damage** (`respawn.lua`): characters you don't control get the game's own "Cancel
  Fall Damage on Reset" flag every 100 ms, so their falls don't hurt you. For other hits
  on them, your health bar is put back and the host sends the hit to its owner.

Things learned the hard way:

- UE4SS 3.0.1 runs Lua hooks on Blueprint functions *after* the function, so parameters
  can't be changed before the call.
- `FindAllOf` walks every object in the game. Three of them every 100 ms starved the
  host's game thread until guest messages arrived 22 s late.
- Many `ExecuteInGameThread` calls per second (and up to 10 `ServerExecRPC` per second)
  went with more crashes. Run periodic work from a game-thread hook instead.
- Game objects cached in Lua become dangling after a level change; even `IsValid()` on
  them can crash.

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
