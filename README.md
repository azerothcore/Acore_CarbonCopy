# Acore_CarbonCopy

A Lua script for [AzerothCore](https://github.com/azerothcore/azerothcore-wotlk) that lets players copy a character's progress onto a new character on the same account, at a level of their choosing - for example to make a PvP twink.

> [!NOTE]
> The copy runs in small steps, one per second, to avoid lag on the server.

**Proudly hosted on [ChromieCraft](https://www.chromiecraft.com/)**
#### Find me on patreon: https://www.patreon.com/Honeys

There is a showcase in the video "[CarbonCopy Feature](https://youtu.be/zDdODWPlbLU?si=vCL9TL34lXSCRklB&t=72)".

## Requirements

- [mod-ale](https://github.com/azerothcore/mod-ale) (**A**zerothCore **L**ua **E**ngine).
- With the default `lua_scripts` folder, `mod_ale.conf` needs `ALE.ScriptPath = "lua_scripts"`; otherwise adjust the path.
- Keep `CarbonCopy.lua`, `CarbonCopy_Config.lua` and `CarbonCopy_Locale.lua` together in one folder.
- Settings are in `CarbonCopy_Config.lua`. After changing it, run `.reload ale` (console, or an administrator in game).
- The database (`Config.customDbName`, default `ac_eluna`) and every table are created and upgraded automatically.

## Player usage

- `.carboncopy` - show your tickets, the cost per level, and whether you can copy from where you are.
- `.carboncopy $newCharacterName` - copy the character you are logged in with to `$newCharacterName`.

### Copy workflow

1. Create a new character with the **same race and class**, on the **same account**. Do **not** log it in.
2. Log in with the character to copy, on one of the allowed maps (`cc_maps`, by default the four continents).
3. Type `.carboncopy $newCharacterName`.
4. **Stay logged in** until the "copy complete" message appears (a few seconds to a minute). The new character is locked while it is being copied.
5. Log in with the new character and collect the items from the mailbox. Enchants and gems are already on them.

If a copy fails before anything was mailed, the tickets are refunded and the new character stays locked until a copy to it succeeds. You can simply run the copy again. If it fails after the items were mailed, the player is asked to contact a GM, who can use `restore`.

## What it copies

- Level, XP, played time, discovered flight paths, explored zones, health / power, bought stable slots.
- The talent setup with both specs (the active spec stays active), glyphs, spells, and skills including professions.
- Completed quests and reputation.
- The action bars.
- The level achievements (level 10, 20, ... 80) the source character has.
- The Hearthstone bind point, only with `homebindToCapital = false` (by default the new character is bound to its faction's capital). If the copied one isn't valid, the capital is used.
- Every equipped item, by mail, with enchants, gems and random suffix. With `makeCopySoulbounded = true` the copies are soulbound.
- A Hearthstone, if the new character doesn't have one.
- Hunters: one pet with its spells - the active pet first, otherwise a dismissed or stabled one.
- Shamans: the totems the source character owns, in their own mail.
- Equipment Manager sets, when `copyEquipmentSets = true` (only gear that was equipped).

By default (each can be turned off):
- the new character starts in its faction's capital (`teleportToCapital`) and is bound there (`homebindToCapital`)
- its talents are reset at first login so the player spends them again (`resetTalentsAfterCopy`, glyphs are kept).

## What it does not copy

- Items in bags and the bank, and the bags themselves.
- Gold (the new character starts with 0 copper).
- Achievements other than the level ones.
- Macros. Copy the character's folder in the client's `WTF` folder for those.

## Tickets

Every copy costs tickets: 1 with `ticketCost = "single"`, or by level with `ticketCost = "level"` (the `ticket_Cost` brackets).

- **Starter tickets:** an account gets `freeTickets` once, the first time it creates a character or logs in.
- **Adding tickets:** GMs, the console and the website add tickets on top of the current balance. A balance can't go above 1000.
- **Realms:** every balance lists the realms it is valid on (the `realm_ids` column): `-1` for all realms, `1`, or `1 2` for one balance shared by realms 1 and 2. A worldserver uses the account's balance whose list contains its own realm id.
- **`ticketRealms`:** this setting is only the list a new balance gets. It must include the realm itself, or be `-1`.
- **Changing realms later:** use `.carboncopy tickets move`, which changes the list of existing balances in place and merges balances where needed.

## Administrator usage

Ranks: tickets, `config` and `logs` need `minGMRankForTickets`; `restore`, `revoke` and `cleanup` need `minGMRankForRestore`. Everything except copying also works from the console.

Wherever a command takes `$characterName`, you can also write `--character $characterName`, or `--account $accountName` to target the account. With `restore` / `revoke`, `--account` runs the command for every character of that account that has logged items.

### Tickets

- `.carboncopy help` - list every command.
- `.carboncopy tickets lookup $characterName` - the account's balance on this realm.
- `.carboncopy tickets add $characterName $amount` - add tickets (0-1000, the total can't pass 1000).
- `.carboncopy tickets remove $characterName $amount`
- `.carboncopy tickets move --account $accountName $toRealms` - give the balance this account uses here a new realm list.
  - Example: `.carboncopy tickets move --account Ryan "1 2"` makes the balance valid on realms 1 and 2.
  - If the account already has a balance for realms in the new list, it is added in and that row is removed.
- `.carboncopy tickets move $fromRealms $toRealms` - the same for every balance whose list is exactly `$fromRealms`.
  - Example: `.carboncopy tickets move 1 -1` makes all realm 1 balances valid everywhere.
- `.addcctickets $characterName $amount` - kept for compatibility.
- `CCACCOUNTTICKETS $accountName $amount` - console / [SOAP](https://www.azerothcore.org/wiki/remote-access#soap), used by [acore-cms](https://github.com/azerothcore/acore-cms).
  - It replies nothing when the tickets were added. Any reply means they were not added (amount refused, account not found).

### Restore and revoke

Every item a copy mails is logged with its enchants, gems and suffix (`enableMailItemLog`). The mails stay `mailExpireDays` (default: the core's 30 days, `0` = never). Expired copy mail is deleted, not returned. The log is kept `mailItemLogRetentionDays`: by default as long as the mails stay, so restore / revoke work until the mail expires.

- `.carboncopy restore $characterName` - list the logged items and where each one is now (mailbox, bags, bank, missing).
- `.carboncopy restore $characterName missing [copyId] [--kick] [--clear]` - re-send only the items that no longer exist.
- `.carboncopy restore $characterName all [copyId] [--kick] [--clear]` - re-send every logged item.
- `.carboncopy revoke $characterName` - preview what a revoke would take back.
- `.carboncopy revoke $characterName all [copyId] [--kick] [--clear]` - take back every logged item still unclaimed in the mailbox.
- `.carboncopy revoke $characterName #logId [--kick] [--clear]` - take back one item (`#logId` from the list).
- `.carboncopy cleanup $days` - delete mail log entries that are `$days` days old or older. `mailItemLogRetentionDays` does it automatically (at startup and once a day).

Options:
- `--kick`: the character must be offline. `--kick` kicks it, waits until it is saved, then runs.
- `--clear` on restore: deletes the log entries once done.
- `--clear` on revoke: deletes the entries instead of marking them revoked.

### Config and logs

- `.carboncopy config` (or `settings`) - show every active setting.
- `.carboncopy logs` - the player log, newest first, 20 rows.
- `.carboncopy logs --source name|guid --target name|guid --day YYYY-MM-DD --code N --limit N --oldest` - filtered.
  - `--code`: `0` = starter tickets, `1` = success, `2` = failed.
  - `--limit`: 1-100.
  - `.carboncopy logs help` lists the flags.

The admin log table records GM and console actions with codes `3` add, `4` remove, `5` lookup, `6` restore, `7` revoke, `8` cleanup and `9` move.

## Configuration

Everything is in `CarbonCopy_Config.lua`, with a comment on each setting. Unlike the original script, by default the new character's talents are reset, it starts and is bound in its faction's capital, and empty slots get no filler item. For the original behaviour set `resetTalentsAfterCopy`, `teleportToCapital` and `homebindToCapital` to `false` and `emptySlotFiller = 38`.

When a setting is invalid, CarbonCopy refuses to load and prints every problem as `ASSERT FAILED - ERROR in CarbonCopy_Config.lua`. With `shutdownOnConfigError = true` (default) it also shuts the worldserver down after 10 seconds, with exit code 1 and the reason `mod-ale lua_scripts/Acore_CarbonCopy/CarbonCopy.lua ASSERT`.

| Setting | Default | |
|---|---|---|
| `shutdownOnConfigError` | `true` | Shut the server down when the config is invalid. |
| `customDbName` | `ac_eluna` | Database for the CarbonCopy tables. |
| `carboncopyTableName`, `playerLogsTableName`, `adminLogsTableName`, `mailItemsTableName` | `carboncopy`, ... | Table names. |
| `enablePlayerLogs`, `enableAdminLogs`, `enableMailItemLog` | `true` | Logging. |
| `mailItemLogRetentionDays` | `-1` | Delete mail log entries after this many days (-1 = as long as the mails stay, see `mailExpireDays`; 0 = never). |
| `mailItemLogRetentionDaysFallback` | `0` | Used (with a warning at startup) when `mailItemLogRetentionDays` isn't valid. Same values. |
| `minGMRankForCopy` / `minGMRankForTickets` / `minGMRankForRestore` | `0` / `2` / `2` | Ranks. |
| `ticketRealms` | `"1"` | Realm list of new balances (see Tickets). |
| `freeTickets` | `4` | Starter tickets per account. |
| `ticketCost` | `"level"` | `"single"` or `"level"`. |
| `maxLevel` | `79` | Highest level that can be copied. |
| `ticket_Cost[...]` | 1 / 2 / 3 / 25 | Cost per level bracket. |
| `cc_maps[...]` | 0, 1, 530, 571 | Maps the copy can start on. |
| `keepStartingItems` | `false` | Keep the new character's own items (false = all but the Hearthstone are deleted). |
| `copyEquipmentSets` | `false` | Copy Equipment Manager sets. |
| `makeCopySoulbounded` | `true` | Copies and restores get the soulbound flag (false = keep the original flags). |
| `resetTalentsAfterCopy` | `true` | Reset talents at first login. |
| `teleportToCapital` / `homebindToCapital` | `true` | Start / bind in the faction's capital (`capitalPositions`, `allianceRaces`, `hordeRaces`). |
| `mailExpireDays` | `-1` | Days the mails stay (-1 = core default, 0 = never). |
| `mailSignature` | `the team of ChromieCraft!` | Signature of the mails. Their texts, in all languages, are in `CarbonCopy_Locale.lua`. |
| `emptySlotFiller` | `0` | Item sent for empty slots so every mail is full (0 = off, 38 = Recruit's Shirt like the original script). |
| `doneMessageDelay` | `5` | Seconds before the "copy complete" message. |
| `pollIntervalMs` / `pollMaxAttempts` | `250` / `60` | How often and how long to wait for logouts and mail saves. |

## Languages

All texts that players and GMs see are in `CarbonCopy_Locale.lua`, in the 9 client languages (enUS, koKR, frFR, deDE, zhCN, zhTW, esES, esMX, ruRU). The command syntax and the logs viewer are English only.

## Tables

- `carboncopy` - ticket balances.
  - Columns: `account_id`, `tickets`, `allow_copy_from_id` (reserved), `starter_tickets_given`, `realm_ids`.
  - The key is `account_id` + `realm_ids`.
- `carboncopy_charges` - ticket deductions in progress, normally empty.
- `carboncopy_player_logs` and `carboncopy_admin_logs`.
- `carboncopy_mail_items` - the mailed-item log used by restore and revoke.

Example: give every existing balance one extra ticket:

```sql
UPDATE ac_eluna.carboncopy SET tickets = LEAST(tickets + 1, 1000);
```

Prefer the commands for single accounts. If you insert rows by hand, give each account at most one row per realm (e.g. not both `1` and `1 2`). CarbonCopy warns about such accounts in the server log at startup.

Find me on patreon: https://www.patreon.com/Honeys
