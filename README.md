# Acore_CarbonCopy

It's a Lua script made for [AzerothCore](https://github.com/azerothcore/azerothcore-wotlk) to allow players to make copies of their characters at specific level of their choosing, an example allowing to have a PVP Twink.

> [!NOTE]
> This script delays the copy process and splits it into 10 pieces to reduce core / server lag.


**Proudly hosted on [ChromieCraft](https://www.chromiecraft.com/)**
#### Find me on patreon: https://www.patreon.com/Honeys

There a showcase of the video "[CarbonCopy Feature](https://youtu.be/zDdODWPlbLU?si=vCL9TL34lXSCRklB&t=72)".

## Requirements:

- Requires [mod-ale](https://github.com/azerothcore/mod-ale) (**A**zerothCore **L**ua **E**ngine) to work.

- If you're using the default `lua_scripts` folder than your `mod_ale.conf` should have `ALE.ScriptPath = "lua_scripts"`, otherwise adjust the path accordingly.

- Requires setup of `CarbonCopy_Config.lua` file if you wish to change the values. (`.reload ale` will update the server with the configuration of the file related to the `CarbonCopy` script.)

- Adjust `local CarbonCopyConfig = require("CarbonCopy_Config")` of your `CarbonCopy.lua` to match the path of your configuration, by default these two files `CarbonCopy.lua` and `CarbonCopy_Config.lua` should be in the same place.

## Player Usage:

- `.carboncopy help`
- `.carboncopy` - Show your current tickets (to be used in-game.)
- `.carboncopy $newCharacterName` - To Start Carbon Copy to given character name.

## Adminstrator Usage:

- `.carboncopy tickets help`
- `.carboncopy tickets lookup CharacterName` - See how many tickets a character has.
- `.carboncopy tickets add CharacterName Amount` - Add tickets to a character's account.
- `.carboncopy tickets remove CharacterName Amount` - Remove tickets from a character's account.
- `.addcctickets help` - [Kept for: Legacy/Compatibility]
- `.addcctickets CharacterName Amount`- [Kept for: Legacy/Compatibility] Add tickets to a character's account.
- `CCACCOUNTTICKETS accountName amount` - Used by [SOAP](https://www.azerothcore.org/wiki/remote-access#soap) for [acore-cms](https://github.com/azerothcore/acore-cms).

## Configuration

```
customDbName = "ac_eluna" -- Name of the database schema used for CarbonCopy data.
minGMRankForCopy = 0 -- Minimum GM rank required to use .carboncopy.
minGMRankForTickets = 2 -- Minimum GM rank required to add or remove tickets.
freeTickets = 4 -- Tickets granted when an account uses CarbonCopy for the first time.
mailText = ",\n \n here you are your gear. Have fun with the new twink!\n \n- Sincerely,\n the team of ChromieCraft!" -- Text included in the item mail.
maxLevel = 79 -- Maximum source character level allowed for copying.
ticketCost = "level" -- "single" = always 1 ticket, "level" = use ticket_Cost table.
keepStartingItems = false -- true = keep target character's existing gear/items, false = delete all except Hearthstone before sending copied gear.
copyEquipmentSets = false -- true = copy Equipment Manager sets with remapped item GUIDs.

ticket_Cost[19] = 1 -- Cost to copy characters up to level 19.
ticket_Cost[29] = 1 -- Cost to copy characters up to level 29.
ticket_Cost[39] = 1 -- Cost to copy characters up to level 39.
ticket_Cost[49] = 1 -- Cost to copy characters up to level 49.
ticket_Cost[59] = 2 -- Cost to copy characters up to level 59.
ticket_Cost[69] = 2 -- Cost to copy characters up to level 69.
ticket_Cost[79] = 3 -- Cost to copy characters up to level 79.
ticket_Cost[80] = 25 -- Cost to copy level 80 characters.
-- This can be scable to any level up or down, if scale up make sure maxLevel also gets updated.

cc_maps[1] = 0 -- Eastern Kingdoms
cc_maps[2] = 1 -- Kalimdor
cc_maps[3] = 530 -- Outland
cc_maps[4] = 571 -- Northrend
-- This allows custom maps if any are used.
```

Set the conf flags in the top section of the .lua file.

You need to grant account related tickets in the `carboncopy` table:
- `account_id` is the unique account ID.
- `tickets` is the number of times an account can copy a character.
- `allow_copy_from_id` is reserved for future use.

You can also grant tickets from console or SOAP:
- `CCACCOUNTTICKETS accountName amount`

You can grant or remove tickets in game (default restriction: GM rank 2+):
- `.carboncopy tickets add characterName amount`
- `.carboncopy tickets remove characterName amount`
- `.addcctickets characterName amount` (kept for legacy compatibility)

**Most important setting: `ticketCost`**
- If set to `single`, every copy costs 1 ticket.
- If set to `level`, ticket cost is determined by the `ticket_Cost[...]` brackets.

**Optional settings**
- `keepStartingItems`: When `true`, the target character keeps existing starter/equipped items. When `false`, all target items except Hearthstone are deleted before copied gear is mailed.
- `copyEquipmentSets`: When `true`, Equipment Manager sets are copied and remapped to the new mailed item GUIDs. This requires the in-game "Use Equipment Manager" feature to be enabled. **Design note:** Only currently equipped items are included in equipment set copying to minimize server queries and load. This means equipment sets will only contain properly remapped items for gear that was actively equipped. Any set slots that referenced non-equipped items will show as empty (0) in the copied set.

## Copy Workflow


- Create a new character with same class/race as the one to copy in the same account. Do NOT log it in.
- Log in with the source character
- While logged in on the character to copy from, do `.carboncopy $newToonsName`
- **WAIT** for a minute before you log out.
- Log on the new character, find a mailbox. Possibly the items in the mail show no enchants/gems. Once you take the items out of the mailbox, all modifications will be visible. On latest AC modifications are visible in the mailbox already.

## What it does:
- Deletes the new character's starter gear, except the Hearthstone.
- Sends copies of all equipped items to the new character by mail, including gems and enchants.
- Copies homebind (inn/hearth location) to the new character.
- Copies level, XP, discovered flight masters, played time, stats, explored zones, and homebind.
- For Hunters, copies the **oldest** pet and bought stable slots (pet talent points are refunded).
- For Shamans, copies low level totems if the source character still has them.
- Copies completed quests, reputation, talents, glyphs, spells, and character skills (including professions).
- Places actions on the new character's bars.
- Optionally copies Equipment Manager sets when `copyEquipmentSets = true`.
- If you copy macro data from one character's `/wtf/` folder to the other, macro setup is usually not needed.

## What it **NOT** does:
- Does not copy bag or bank items.
- Does not copy bag containers.
- Does not copy gold; the new character starts at 0 copper.
- Does not copy achievements.

Example query to add one free ticket to all existing accounts:

`REPLACE INTO ac_eluna.carboncopy(account_id) SELECT id FROM acore_auth.account;`
`UPDATE  ac_eluna.carboncopy SET tickets = 1;`

Find me on patreon: https://www.patreon.com/Honeys
