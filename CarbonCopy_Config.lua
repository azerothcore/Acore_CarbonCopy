local Config = {}
local cc_maps = {}
local ticket_Cost = {}

-- Every option below has the same default as CarbonCopy had before it existed,
-- so an existing server behaves the same until you change something.

-- When a setting below is invalid, CarbonCopy refuses to load and prints every problem (an ASSERT).
-- true = also shut the world server down (10 second countdown), so it never runs with a broken CarbonCopy.
-- false = only CarbonCopy stops; the rest of the server keeps running.
Config.shutdownOnConfigError = true

----------------------------------------------------------------------------------------------------
-- Database
----------------------------------------------------------------------------------------------------

-- Database (schema) for the CarbonCopy tables. Created automatically if it doesn't exist.
Config.customDbName = 'ac_eluna'

-- Table names inside Config.customDbName
Config.carboncopyTableName = 'carboncopy'               -- tickets per account
Config.playerLogsTableName = 'carboncopy_player_logs'
Config.adminLogsTableName = 'carboncopy_admin_logs'
Config.mailItemsTableName = 'carboncopy_mail_items'     -- items mailed by copies, used by .carboncopy restore / revoke

-- Write the player and admin logs (true = yes | false = no). Their tables are created automatically.
Config.enablePlayerLogs = true
Config.enableAdminLogs = true

-- Log every item a copy mails, with its enchants, gems and random suffix, so GMs can use
-- .carboncopy restore / revoke (true = yes | false = no). Players don't notice anything.
Config.enableMailItemLog = true

-- Delete mailed-item log entries automatically once they are this many days old (checked at startup and once a day).
-- -1 = as long as the mails stay (Config.mailExpireDays: its -1 is the core's 30 days, its 0 is never),
-- 0 = never, 1 = 1 day, ... GMs can also run .carboncopy cleanup $days.
Config.mailItemLogRetentionDays = -1

-- Used instead when mailItemLogRetentionDays isn't valid (a warning is printed at startup, CarbonCopy still loads).
-- Same values: -1 = as long as the mails stay, 0 = never, 1 = 1 day, ...
Config.mailItemLogRetentionDaysFallback = 0

----------------------------------------------------------------------------------------------------
-- Permissions
----------------------------------------------------------------------------------------------------

-- Minimum GM rank to use .carboncopy. 0 = every player.
Config.minGMRankForCopy = 0

-- Minimum GM rank to manage tickets and see the config / logs.
Config.minGMRankForTickets = 2

-- Minimum GM rank for .carboncopy restore, revoke and cleanup.
Config.minGMRankForRestore = 2

----------------------------------------------------------------------------------------------------
-- Tickets
----------------------------------------------------------------------------------------------------

-- Ticket balances are per account and list the realms they are valid on (the realm_ids column). Each worldserver
-- uses the account's balance that contains its own realm id (from the core), or "-1" (all realms).
-- This setting is the realm list a NEW balance gets on this worldserver; it must include this realm or be "-1":
--   "-1"     = valid on every realm (worldservers using the same Config.customDbName)
--   "1"      = valid on realm 1 only
--   "1 2"    = one balance shared by realms 1 and 2
-- -1 can't be combined with realm ids. To change the realms of existing balances use
-- .carboncopy tickets move (one account with --account, or every balance with a given list).
Config.ticketRealms = "1"

-- Starter tickets: an account without tickets gets this many when it creates a character or logs in with any character.
-- Changing it only affects accounts that haven't received them yet; existing balances are never touched.
Config.freeTickets = 4

-- "single" = every copy costs 1 ticket. "level" = the cost depends on the level (ticket_Cost below).
Config.ticketCost = "level"

-- Highest level a character can be copied at.
Config.maxLevel = 79

-- Cost per level when Config.ticketCost = "level": each entry covers the levels up to that number.
ticket_Cost[19] = 1
ticket_Cost[29] = 1
ticket_Cost[39] = 1
ticket_Cost[49] = 1      -- levels  1-49: 1 ticket
ticket_Cost[59] = 2
ticket_Cost[69] = 2      -- levels 50-69: 2 tickets
ticket_Cost[79] = 3      -- levels 70-79: 3 tickets
ticket_Cost[80] = 25     -- level  80:   25 tickets (only if Config.maxLevel is 80)

-- Maps the source character must be on to use .carboncopy, so dungeon-only gear
-- (e.g. the Kael'thas legendaries) can't be copied.
cc_maps[1] = 0           -- Eastern Kingdoms
cc_maps[2] = 1           -- Kalimdor
cc_maps[3] = 530         -- Outland
cc_maps[4] = 571         -- Northrend

----------------------------------------------------------------------------------------------------
-- The new character
----------------------------------------------------------------------------------------------------

-- Keep the new character's starting items (true) or delete them all except the Hearthstone (false).
Config.keepStartingItems = false

-- Copy equipment sets (true = yes | false = no). Needs "Use Equipment Manager" in Interface > Features.
Config.copyEquipmentSets = false

-- Copied and restored items: true = add the soulbound flag to the original item's flags.
-- false = keep the original item's flags exactly (soulbound stays soulbound, an unbound BoE stays unbound).
Config.makeCopySoulbounded = true

-- Reset the new character's talents on both specs at its first login, so the player spends them again.
-- Glyphs are kept. (true = yes | false = no)
Config.resetTalentsAfterCopy = true

-- Where the new character starts: true = its faction's capital (capitalPositions), false = where it was created.
Config.teleportToCapital = true

-- Hearthstone bind point: true = its faction's capital (capitalPositions), false = copied from the source character.
-- If the copied bind point isn't valid (none, not on a continent, all zero) the faction's capital is used instead.
Config.homebindToCapital = true

-- Which races use which capital. Races in neither list (e.g. custom races) use the neutral position.
Config.allianceRaces = { 1, 3, 4, 7, 11 }   -- Human, Dwarf, Night Elf, Gnome, Draenei
Config.hordeRaces    = { 2, 5, 6, 8, 10 }   -- Orc, Undead, Tauren, Troll, Blood Elf

-- Capital positions: map, zone, x, y, z, o (orientation)
Config.capitalPositions = {
    alliance = { map = 0, zone = 1519, x = -8865.09,   y = 671.793,   z = 97.9034,   o = 2.16098 },  -- Stormwind, Trade District
    horde    = { map = 1, zone = 1637, x = 1633.8,     y = -4440.47,  z = 15.634,    o = 3.08343 },  -- Orgrimmar, Valley of Strength
    neutral  = { map = 0, zone = 33,   x = -14468.104, y = 483.00665, z = 26.776731, o = 0.0 },      -- Booty Bay
}

----------------------------------------------------------------------------------------------------
-- Mail
----------------------------------------------------------------------------------------------------

-- Days the copy / restore mails stay in the mailbox. -1 = core default (30 days), 0 = never (until 2038).
-- Expired GM mail is deleted together with its items, it is never returned.
Config.mailExpireDays = -1

-- Signature at the end of the copy / restore mails. The mail texts (all languages) are in CarbonCopy_Locale.lua.
Config.mailSignature = "the team of ChromieCraft!"

-- Item sent in place of empty equipment slots and missing Shaman totems, so every mail is full.
-- 0 = send only the real items. 38 = Recruit's Shirt (what the original script sent).
Config.emptySlotFiller = 0

----------------------------------------------------------------------------------------------------
-- Timing
----------------------------------------------------------------------------------------------------

-- Seconds between the copy being finished (new character unlocked) and telling the player they can log out.
Config.doneMessageDelay = 5

-- While a character is locked for a copy / restore / revoke: how often (milliseconds, minimum 50) to check that a
-- kicked character is offline and the mails are saved, and how many checks before giving up (250 x 60 = 15 seconds).
Config.pollIntervalMs = 250
Config.pollMaxAttempts = 60

return {
    Config = Config,
    cc_maps = cc_maps,
    ticket_Cost = ticket_Cost,
}
