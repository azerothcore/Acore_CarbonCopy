local Config = {}
local cc_maps = {}
local ticket_Cost = {}

-- Name of Eluna dB scheme
Config.customDbName = 'ac_eluna'
-- Min GM Level to use the .carboncopy command. Set to 0 for all players.
Config.minGMRankForCopy = 0
-- Min GM Level to add tickets to an account.
Config.minGMRankForTickets = 2
-- The amount of free tickets to grant when .carboncopy is executed for the first time on that account
Config.freeTickets = 4
-- This text is added to the mail which the new character receives alongside their copied items
Config.mailText = ",\n \n here you are your gear. Have fun with the new twink!\n \n- Sincerely,\n the team of ChromieCraft!"
-- Maximum level to allow copying a character.
Config.maxLevel = 79
-- Whether the ticket amount withdrawn for a copy is always 1 (set it to "single") or depends on the level (set this to "level")
Config.ticketCost = "level"
-- Whether to copy equipment sets to the new character (requires "Use Equipment Manager" enabled in Interface > Features)
Config.copyEquipmentSets = true
-- Here you can adjust the cost in tickets if Config.ticketCost is set to "level"
ticket_Cost[19] = 1
ticket_Cost[29] = 1
ticket_Cost[39] = 1
ticket_Cost[49] = 1      -- it costs 1 ticket to copy a character up to level 49
ticket_Cost[59] = 2
ticket_Cost[69] = 2      -- it costs 2 tickets to copy a character up to level 69
ticket_Cost[79] = 3      -- it costs 3 tickets to copy a character up to level 79
ticket_Cost[80] = 25     -- it costs 25 tickets to copy a character at level 80

-- The ItemID "38" (Recruit's Shirt) will be sent on the mail if slot is empty or doesn't exist.
-- Applies for Shaman Totems "totemItem[X]" and for nill slots in "item_id[i]".

-- The maps below specify legal locations to use the .carboncopy command.
-- This is used to prevent dungeon specific gear to be copied e.g. the legendaries from the Kael'thas encounter.
-- Eastern kingdoms
cc_maps[1] = 0
-- Kalimdor
cc_maps[2] = 1
-- Outland
cc_maps[3] = 530
-- Northrend
cc_maps[4] = 571

return {
    Config = Config,
    cc_maps = cc_maps,
    ticket_Cost = ticket_Cost,
}
