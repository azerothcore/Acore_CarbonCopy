--
-- Created by IntelliJ IDEA.
-- User: Silvia
-- Date: 18/02/2021
-- Time: 23:28
-- To change this template use File | Settings | File Templates.
-- Originally created by Honey for Azerothcore
-- requires ElunaLua module

------------------------------------------------------------------------------------------------
-- ADMIN GUIDE:  -  compile the core with ElunaLua module
--               -  adjust config in Acore_CarbonCopy/CarbonCopy_Config.lua
--               -  adjust texts / translations in Acore_CarbonCopy/CarbonCopy_Locale.lua
--               -  add this script to ../lua_scripts/
--               -  grant account related tickets in the `carboncopy` table
-- PLAYER USAGE: 1) create a new character with same class/race as the one to copy in the same account. Do NOT log it in
--               2) log in with the source character
--               3) .carboncopy newToonsName
------------------------------------------------------------------------------------------------

local CarbonCopyConfig = require("CarbonCopy_Config")
local L = require("CarbonCopy_Locale")

-- All texts live in CarbonCopy_Locale.lua.
-- cc_tl(locale, key, ...) : text for a locale id (falls back to enUS [0]), string.format'ed with the values.
-- cc_t(player, key, ...)  : same, for the player's client locale (player nil = console / log = enUS).
local function cc_tl(locale, key, ...)
    local entry = L[key]
    local text = (type(entry) == "table" and (entry[locale or 0] or entry[0])) or entry or key
    if select('#', ...) > 0 then
        return string.format(text, ...)
    end
    return text
end

local function cc_t(player, key, ...)
    return cc_tl(player and player:GetDbcLocale() or 0, key, ...)
end
local cc_info = cc_t

-- "GM Name" or "The console", for the ticket messages
local function cc_actor(player)
    if player == nil then
        return cc_t(nil, "ACTOR_CONSOLE")
    end
    return cc_t(player, "ACTOR_GM", player:GetName())
end

local Config = CarbonCopyConfig.Config
local cc_maps = CarbonCopyConfig.cc_maps
local ticket_Cost = CarbonCopyConfig.ticket_Cost

-- Settings (see CarbonCopy_Config.lua). Each fallback below is what CarbonCopy did before the option existed,
-- so an older config file without these keys keeps the old behaviour.
local cc_carboncopyTable = Config.carboncopyTableName or "carboncopy"
-- CHECK constraint names must be unique in the whole database on MySQL 8, so the name includes the table name
local CC_REALM_CHECK = "chk_"..tostring(cc_carboncopyTable).."_realm_ids"
-- Realm lists (Config.ticketRealms, the realm_ids column, tickets move): "-1" = all realms, or realm ids ("1", "1 2").
-- Normalised (sorted, single spaces) so the same set is always written the same way. "-1" can't be mixed with ids.
local function cc_parseTicketRealms(value)
    local text = tostring(value or "-1")
    local ids, seen, hasAll = {}, {}, false
    for token in text:gmatch("[^%s,]+") do
        local id = token:match("^%-?%d+$") and tonumber(token) or nil
        if id ~= nil and id > 2147483647 then
            return nil, "'"..token.."' is too large for a realm id"
        end
        if id == -1 then
            hasAll = true
        elseif id == nil or id < 1 or id ~= math.floor(id) then
            return nil, "'"..token.."' is not a realm id"
        elseif not seen[id] then
            seen[id] = true
            table.insert(ids, id)
        end
    end
    if hasAll and #ids > 0 then
        return nil, "-1 (all realms) can't be combined with realm ids"
    end
    if #ids == 0 then
        return "-1"
    end
    table.sort(ids)
    return table.concat(ids, " ")
end
local CC_TICKET_REALMS, cc_realmsError = cc_parseTicketRealms(Config.ticketRealms or Config.ticketRealm)
if CC_TICKET_REALMS == nil then
    CC_TICKET_REALMS = "-1"   -- only so the rest of this file can load; the config check below stops CarbonCopy
end
-- only digits, spaces and "-1" left after parsing, so it can go into SQL as a quoted literal
local CC_TICKET_REALMS_SQL = "'"..CC_TICKET_REALMS.."'"
-- This worldserver's realm id, from the core. A balance applies here when its realm_ids is -1 or contains this id,
-- so one row can serve several realms ("1 2"). Config.ticketRealms is the list a new balance starts with.
local CC_REALM_ID = math.floor(tonumber(GetRealmID and GetRealmID() or 1) or 1)
local CC_MY_BALANCE_SQL = "(`realm_ids` = '-1' OR FIND_IN_SET('"..CC_REALM_ID.."', REPLACE(`realm_ids`, ' ', ',')) > 0)"

-- How characters are shown: "Name (Low GUID / ID: 5)".
local function cc_characterLabel(name, guid)
    return tostring(name).." (Low GUID / ID: "..tostring(guid)..")"
end

-- How accounts are shown everywhere: "NAME (ID: 5)".
local function cc_accountLabel(accountId)
    local q = AuthDBQuery('SELECT `username` FROM `account` WHERE `id` = '..tonumber(accountId)..' LIMIT 1;')
    return (q and q:GetString(0) or "?").." (ID: "..accountId..")"
end
local cc_playerLogsTable = Config.playerLogsTableName or "carboncopy_player_logs"
local cc_adminLogsTable = Config.adminLogsTableName or "carboncopy_admin_logs"
local cc_mailItemsTable = Config.mailItemsTableName or "carboncopy_mail_items"
local cc_enablePlayerLogs = Config.enablePlayerLogs ~= false
local cc_enableAdminLogs = Config.enableAdminLogs ~= false
local cc_enableMailItemLog = Config.enableMailItemLog ~= false
local cc_minGMRankForRestore = tonumber(Config.minGMRankForRestore) or tonumber(Config.minGMRankForTickets) or 2

local cc_makeCopySoulbounded = Config.makeCopySoulbounded ~= false
local cc_resetTalentsAfterCopy = Config.resetTalentsAfterCopy == true
local cc_teleportToCapital = Config.teleportToCapital == true
local cc_homebindToCapital = Config.homebindToCapital == true
local cc_allianceRaces = Config.allianceRaces or { 1, 3, 4, 7, 11 }
local cc_hordeRaces = Config.hordeRaces or { 2, 5, 6, 8, 10 }
local cc_capitalPositions = Config.capitalPositions or {
    alliance = { map = 0, zone = 1519, x = -8865.09,   y = 671.793,   z = 97.9034,   o = 2.16098 },  -- Stormwind, Trade District
    horde    = { map = 1, zone = 1637, x = 1633.8,     y = -4440.47,  z = 15.634,    o = 3.08343 },  -- Orgrimmar, Valley of Strength
    neutral  = { map = 0, zone = 33,   x = -14468.104, y = 483.00665, z = 26.776731, o = 0.0 },      -- Booty Bay
}
local CC_CONTINENTS = { 0, 1, 530, 571 }   -- maps a Hearthstone bind point may be on

local cc_mailExpireDays = tonumber(Config.mailExpireDays) or -1
-- days the core keeps mail when CarbonCopy doesn't set an expiry (Config.mailExpireDays = -1)
local CC_CORE_MAIL_EXPIRE_DAYS = 30
-- Config.mailItemLogRetentionDays: -1 = as long as the mails stay, 0 = never, N = N days. Not valid: a warning, and
-- Config.mailItemLogRetentionDaysFallback (same values) is used instead.
local function cc_validRetention(value)
    return type(value) == "number" and value == math.floor(value) and value >= -1
end
local cc_mailLogRetentionSetting = Config.mailItemLogRetentionDays
if cc_mailLogRetentionSetting == nil then
    cc_mailLogRetentionSetting = -1   -- not in the config file: the default
end
if not cc_validRetention(cc_mailLogRetentionSetting) then
    local fallback = Config.mailItemLogRetentionDaysFallback
    if fallback == nil then
        fallback = 0
    end
    PrintError("CarbonCopy: Config.mailItemLogRetentionDays must be -1 (as long as the mails), 0 (never) or a number of days, is "
        ..tostring(Config.mailItemLogRetentionDays).." - using Config.mailItemLogRetentionDaysFallback ("..tostring(fallback)..") instead.")
    cc_mailLogRetentionSetting = cc_validRetention(fallback) and fallback or 0   -- an invalid fallback is reported at load
end
local cc_mailLogRetentionDays = cc_mailLogRetentionSetting
if cc_mailLogRetentionSetting < 0 then
    if cc_mailExpireDays < 0 then
        cc_mailLogRetentionDays = CC_CORE_MAIL_EXPIRE_DAYS
    else
        cc_mailLogRetentionDays = math.floor(cc_mailExpireDays)   -- 0 = mails never expire: keep the log too
    end
end
local cc_mailSignature = Config.mailSignature or "the team of ChromieCraft!"
local cc_emptySlotFiller = tonumber(Config.emptySlotFiller) or 0
-- Older configs have Config.mailText (the whole English gear mail text after "Hello Name") instead of mailSignature.
-- When it's there and mailSignature isn't, the copy mails use it as before.
local cc_legacyMailText = (Config.mailSignature == nil) and Config.mailText or nil

local cc_doneMessageDelay = math.max(0, tonumber(Config.doneMessageDelay) or 5)

-- Capital position for a race: alliance / horde list, anything else gets the neutral one.
local function cc_capitalForRace(race)
    for _, r in ipairs(cc_allianceRaces) do
        if r == race then return cc_capitalPositions.alliance end
    end
    for _, r in ipairs(cc_hordeRaces) do
        if r == race then return cc_capitalPositions.horde end
    end
    return cc_capitalPositions.neutral
end

-- SQL for the flags of a copied item, from the original's flags (column or number).
local function cc_copyFlagsSql(sourceFlags)
    if cc_makeCopySoulbounded then
        return '(('..sourceFlags..') | 1)'
    end
    return '('..sourceFlags..')'
end

-- Ban reasons used to lock a character during a copy / restore / revoke. The script only ever lifts bans with these reasons.
local CC_BAN_REASON_COPY = "CarbonCopy"
local CC_BAN_REASON_RESTORE = "CarbonCopy restore"
local CC_BAN_REASON_REVOKE = "CarbonCopy revoke"

-- While a character is locked, check every pollIntervalMs (up to pollMaxAttempts times) whether it is offline and
-- its mail is saved, so the lock only lasts as long as the work really takes.
local CC_POLL_MS = math.max(50, tonumber(Config.pollIntervalMs) or 250)
local CC_POLL_MAX = math.max(1, tonumber(Config.pollMaxAttempts) or 60)
-- How long a lock lasts if the script never lifts it: the longest wait (polling) plus 30 s, at least 45 s.
-- A restore / revoke with --kick can wait twice (offline, then the mail commit), so twice the polling window.
local CC_LOCK_SECONDS = math.max(45, math.ceil(2 * CC_POLL_MS * CC_POLL_MAX / 1000) + 30)
-- A copy that is still busy after this long is failed by the next command: its steps (about 15 s) plus the mail polling.
local CC_WATCHDOG_SECONDS = math.max(120, math.ceil(CC_POLL_MS * CC_POLL_MAX / 1000) + 60)

-- "Never expires" = 2038-01-01. Kept below 2^31 so no signed 32-bit time math (core or client) can overflow it.
local CC_MAIL_NEVER_EXPIRES = 2145916800
local cc_unpack = table.unpack or unpack


------------------------------------------
-- NO ADJUSTMENTS REQUIRED BELOW THIS LINE
------------------------------------------

--Globals (see cleanup function for non-arrays)
cc_oldItemGuids = {}
cc_newItemGuids = {}
cc_scriptIsBusy = 0
cc_newCharacterName = nil
cc_copyTicketsBefore = nil
cc_copyTicketsAfter = nil
cc_totemMailGuids = {}      -- every item guid in the shaman totem mail (fillers included), used to find the mail
cc_totemItemGuids = {}      -- only the real totems, used for the mailed-items log
cc_fixItemsAttempts = 0
cc_restoreBusy = {}         -- target guid -> true while a restore for that character is being finalised
cc_copyLocale = 0           -- locale of the copying player, used for the copy mails
cc_copyAccountId = nil      -- account charged for the running copy
cc_copyCharged = 0          -- tickets taken for the running copy (refunded if it fails before anything is mailed)
cc_copyMailed = false       -- true once copy mails went out (no refund after that)
cc_copyStartedAt = nil      -- os.time() the running copy started, for the watchdog
cc_copyToken = 0            -- changes with every copy start / end, so a late cc_fixItems of an older copy does nothing

-- If module runs for the first time, create the db specified in Config.dbName and add the "carboncopy" table to it.
----------------------------------------------------------------------------------------------------
-- Config check (ASSERT): CarbonCopy refuses to load with settings it can't work with, and lists every problem at once.
-- A failed assert while loading stops this file, so no command or event below gets registered.
----------------------------------------------------------------------------------------------------
do
    local problems = {}
    local function bad(text)
        table.insert(problems, text)
    end
    local function show(value)
        if type(value) == "string" then return '"'..value..'"' end
        return tostring(value)
    end
    local function isWhole(value, min, max)
        return type(value) == "number" and value == math.floor(value) and value >= (min or -math.huge) and value <= (max or math.huge)
    end
    local function isName(value)
        return type(value) == "string" and value:match("^[%w_]+$") ~= nil
    end

    if not isName(Config.customDbName) then
        bad("Config.customDbName must be a database name (letters, digits, _), is "..show(Config.customDbName))
    end
    if Config.carboncopyTableName ~= nil and isName(Config.carboncopyTableName) and #Config.carboncopyTableName > 50 then
        bad("Config.carboncopyTableName can be at most 50 characters (a constraint is named after it), is "..show(Config.carboncopyTableName))
    end
    for _, key in ipairs({ "carboncopyTableName", "playerLogsTableName", "adminLogsTableName", "mailItemsTableName" }) do
        if Config[key] ~= nil and not isName(Config[key]) then
            bad("Config."..key.." must be a table name (letters, digits, _), is "..show(Config[key]))
        end
    end
    if not isWhole(Config.freeTickets, 0) then
        bad("Config.freeTickets must be a whole number of 0 or more, is "..show(Config.freeTickets))
    end
    if not isWhole(Config.maxLevel, 1, 255) then
        bad("Config.maxLevel must be a level from 1 to 255, is "..show(Config.maxLevel))
    end
    if not isWhole(Config.minGMRankForCopy, 0) then
        bad("Config.minGMRankForCopy must be a whole number of 0 or more, is "..show(Config.minGMRankForCopy))
    end
    if not isWhole(Config.minGMRankForTickets, 0) then
        bad("Config.minGMRankForTickets must be a whole number of 0 or more, is "..show(Config.minGMRankForTickets))
    end
    if Config.ticketCost ~= "single" and Config.ticketCost ~= "level" then
        bad('Config.ticketCost must be "single" or "level", is '..show(Config.ticketCost))
    elseif Config.ticketCost == "level" then
        local highest = nil
        for level, cost in pairs(ticket_Cost or {}) do
            if not isWhole(level, 1) or not isWhole(cost, 0) then
                bad("ticket_Cost["..show(level).."] = "..show(cost).." must be a level from 1 up with a whole cost of 0 or more")
            elseif highest == nil or level > highest then
                highest = level
            end
        end
        if highest == nil then
            bad('ticket_Cost has no entries, but Config.ticketCost is "level"')
        elseif isWhole(Config.maxLevel, 1) and highest < Config.maxLevel then
            bad("ticket_Cost must cover every level up to Config.maxLevel ("..Config.maxLevel.."), its highest entry is "..highest)
        end
    end
    local mapCount = 0
    for _, map in pairs(cc_maps or {}) do
        mapCount = mapCount + 1
        if not isWhole(map, 0) then
            bad("cc_maps entries must be map ids, one is "..show(map))
        end
    end
    if mapCount == 0 then
        bad("cc_maps is empty, nobody could copy anywhere")
    elseif #cc_maps ~= mapCount then
        bad("cc_maps must be numbered 1, 2, 3, ... without gaps (cc_maps[1] = 0, cc_maps[2] = 1, ...)")
    end
    if cc_realmsError ~= nil then
        bad("Config.ticketRealms is invalid ("..cc_realmsError.."), is "..show(Config.ticketRealms or Config.ticketRealm))
    elseif CC_TICKET_REALMS ~= "-1" and not (" "..CC_TICKET_REALMS.." "):find(" "..CC_REALM_ID.." ", 1, true) then
        bad("Config.ticketRealms must include this realm (id "..CC_REALM_ID.." from the core) or be \"-1\", is "
            ..show(Config.ticketRealms or Config.ticketRealm).." - new balances would not be visible on this realm")
    end
    if not isWhole(Config.mailExpireDays or -1, -1) then
        bad("Config.mailExpireDays must be -1 (core default), 0 (never) or a number of days, is "..show(Config.mailExpireDays))
    end
    -- an invalid mailItemLogRetentionDays only warns (its fallback is used); the fallback itself must be valid
    if Config.mailItemLogRetentionDaysFallback ~= nil and not isWhole(Config.mailItemLogRetentionDaysFallback, -1) then
        bad("Config.mailItemLogRetentionDaysFallback must be -1 (as long as the mails), 0 (never) or a number of days, is "
            ..show(Config.mailItemLogRetentionDaysFallback))
    end
    if not isWhole(cc_emptySlotFiller, 0) then
        bad("Config.emptySlotFiller must be 0 or an item id, is "..show(Config.emptySlotFiller))
    elseif cc_emptySlotFiller > 0 and WorldDBQuery('SELECT 1 FROM `item_template` WHERE `entry` = '..cc_emptySlotFiller..' LIMIT 1;') == nil then
        bad("Config.emptySlotFiller is item "..cc_emptySlotFiller..", which doesn't exist in item_template")
    end
    if Config.capitalPositions ~= nil then
        for _, side in ipairs({ "alliance", "horde", "neutral" }) do
            local pos = type(Config.capitalPositions) == "table" and Config.capitalPositions[side] or nil
            if type(pos) ~= "table" then
                bad("Config.capitalPositions."..side.." is missing")
            else
                for _, field in ipairs({ "map", "zone", "x", "y", "z" }) do
                    if type(pos[field]) ~= "number" then
                        bad("Config.capitalPositions."..side.."."..field.." must be a number, is "..show(pos[field]))
                    end
                end
            end
        end
    end

    -- Config.shutdownOnConfigError (default true): also shut the world server down, so it never runs without
    -- CarbonCopy. The shutdown is queued as a console command; the assert below still stops this file right away.
    if #problems > 0 and Config.shutdownOnConfigError ~= false then
        -- This file's path, from lua_scripts on (e.g. lua_scripts/Acore_CarbonCopy/CarbonCopy.lua).
        local luaFile = "CarbonCopy.lua"
        local ok, info = pcall(function() return debug.getinfo(1, "S") end)
        if ok and info and type(info.source) == "string" and info.source:sub(1, 1) == "@" then
            local src = info.source:gsub("^@", ""):gsub("\\", "/")
            luaFile = src:match("(lua_scripts/.+)$") or src:match("([^/]+)$") or luaFile
        end
        PrintError("[CarbonCopy] Config.shutdownOnConfigError is on: shutting the world server down in 10 seconds.")
        -- server shutdown <seconds> [exitCode] [reason]: exit code 1 = error; the reason is shown to players and the console.
        RunCommand("server shutdown 10 1 mod-ale "..luaFile.." ASSERT")
    end
    -- ASSERT: stops this file here (ALE prints the message and a stack trace)
    assert(#problems == 0, "[CarbonCopy] ASSERT FAILED - ERROR in CarbonCopy_Config.lua, CarbonCopy NOT loaded. "
        .."Fix these and run .reload ale:\n  - "..table.concat(problems, "\n  - "))
end

CharDBQuery('CREATE DATABASE IF NOT EXISTS `'..Config.customDbName..'`;');
CharDBQuery('CREATE TABLE IF NOT EXISTS `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` ('
    ..'`account_id` INT(11) NOT NULL, '
    ..'`tickets` INT(11) DEFAULT 0, '
    ..'`allow_copy_from_id` INT(11) DEFAULT 0, '
    ..'`starter_tickets_given` TINYINT(1) NOT NULL DEFAULT 0, '
    ..'`realm_ids` VARCHAR(255) NOT NULL DEFAULT "-1" COMMENT "-1 = all realms, or realm ids separated by spaces", '
    ..'PRIMARY KEY (`account_id`, `realm_ids`), '
    ..'CONSTRAINT `'..CC_REALM_CHECK..'` CHECK (`realm_ids` = "-1" OR `realm_ids` REGEXP "^[1-9][0-9]*( [1-9][0-9]*)*$")'
    ..') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DEFAULT;'
)
-- Tables from before realm_ids existed: add it and make it part of the key. Existing balances get the realms configured
-- now (Config.ticketRealms), so every player keeps what they have. A realm_id column from the single-realm version is
-- converted and dropped.
local function cc_columnExists(tableName, column)
    return CharDBQuery("SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '"..Config.customDbName.."' AND TABLE_NAME = '"
        ..tableName.."' AND COLUMN_NAME = '"..column.."' LIMIT 1;") ~= nil
end
local cc_ticketTableSql = '`'..Config.customDbName..'`.`'..cc_carboncopyTable..'`'

-- One row per ticket deduction while it runs (see the copy's "deduct tickets" step): the deduction and the row's
-- `applied` flag are changed by the same statement, so reading the flag back says exactly whether this copy paid,
-- whatever other worldservers sharing the balance did meanwhile. The row is deleted right after.
local cc_chargesTableSql = '`'..Config.customDbName..'`.`'..cc_carboncopyTable..'_charges`'
CharDBQuery('CREATE TABLE IF NOT EXISTS '..cc_chargesTableSql..' ('
    ..'`token` VARCHAR(64) NOT NULL, '
    ..'`account_id` INT UNSIGNED NOT NULL, '
    ..'`amount` INT NOT NULL, '
    ..'`applied` TINYINT(1) NOT NULL DEFAULT 0, '
    ..'`created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, '
    ..'PRIMARY KEY (`token`)'
    ..') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT="CarbonCopy: ticket deductions in progress (normally empty)";')
CharDBQuery('DELETE FROM '..cc_chargesTableSql..' WHERE `created_at` < NOW() - INTERVAL 1 DAY;')
if not cc_columnExists(cc_carboncopyTable, 'realm_ids') then
    CharDBQuery('ALTER TABLE '..cc_ticketTableSql..' ADD COLUMN `realm_ids` VARCHAR(255) NOT NULL DEFAULT "-1" COMMENT "-1 = all realms, or realm ids separated by spaces";')
    if not cc_columnExists(cc_carboncopyTable, 'realm_id') then
        CharDBQuery('UPDATE '..cc_ticketTableSql..' SET `realm_ids` = '..CC_TICKET_REALMS_SQL..';')
        CharDBQuery('ALTER TABLE '..cc_ticketTableSql..' DROP PRIMARY KEY, ADD PRIMARY KEY (`account_id`, `realm_ids`);')
    end
end
-- realm_id from the single-realm version (also when an earlier conversion stopped half way): convert and drop it
if cc_columnExists(cc_carboncopyTable, 'realm_id') then
    CharDBQuery('UPDATE '..cc_ticketTableSql..' SET `realm_ids` = IF(`realm_id` < 1, "-1", CAST(`realm_id` AS CHAR));')
    CharDBQuery('ALTER TABLE '..cc_ticketTableSql..' DROP PRIMARY KEY, DROP COLUMN `realm_id`, ADD PRIMARY KEY (`account_id`, `realm_ids`);')
    if cc_columnExists(cc_carboncopyTable, 'realm_id') then
        PrintError("CarbonCopy: could not convert "..cc_ticketTableSql..".`realm_id` to `realm_ids` (an account probably has two rows that "
            .."both become \"-1\", e.g. realm_id 0 and -1). Merge those rows by hand; the conversion runs again at the next load.")
    end
end
local function cc_constraintExists(name)
    return CharDBQuery("SELECT 1 FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = '"..Config.customDbName.."' AND TABLE_NAME = '"
        ..cc_carboncopyTable.."' AND CONSTRAINT_NAME = '"..name.."' LIMIT 1;") ~= nil
end
-- the first realm_ids version used a fixed name, which clashes on MySQL 8 when a second ticket table exists
if CC_REALM_CHECK ~= "chk_cc_realm_ids" and cc_constraintExists("chk_cc_realm_ids") then
    CharDBQuery('ALTER TABLE '..cc_ticketTableSql..' DROP CONSTRAINT `chk_cc_realm_ids`;')
end
if not cc_constraintExists(CC_REALM_CHECK) then
    CharDBQuery('ALTER TABLE '..cc_ticketTableSql..' ADD CONSTRAINT `'..CC_REALM_CHECK..'` CHECK (`realm_ids` = "-1" OR `realm_ids` REGEXP "^[1-9][0-9]*( [1-9][0-9]*)*$");')
end
-- Warn about accounts with more than one balance for this realm (e.g. rows "1" and "1 2"): only one of them is used.
-- .carboncopy tickets move never creates that; it can come from rows edited by hand or from older versions.
do
    local q = CharDBQuery('SELECT `account_id`, GROUP_CONCAT(`realm_ids` ORDER BY `realm_ids` SEPARATOR \'" and "\') FROM '..cc_ticketTableSql
        ..' WHERE '..CC_MY_BALANCE_SQL..' GROUP BY `account_id` HAVING COUNT(*) > 1 LIMIT 20;')
    if q ~= nil then
        repeat
            PrintError("CarbonCopy: account "..cc_accountLabel(q:GetUInt32(0)).." has more than one ticket balance for realm "..CC_REALM_ID.." in `"
                ..Config.customDbName.."`.`"..cc_carboncopyTable.."`.`realm_ids` (\""..q:GetString(1).."\"). Merge them into one row "
                .."(add the tickets together, delete the other row).")
        until not q:NextRow()
    end
end

-- Tables from before starter_tickets_given existed: add it, and mark every existing account as having had its starter
-- tickets (they got them the first time they used .carboncopy). Rows written later by anything else default to 0.
if CharDBQuery("SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '"..Config.customDbName.."' AND TABLE_NAME = '"
    ..cc_carboncopyTable.."' AND COLUMN_NAME = 'starter_tickets_given' LIMIT 1;") == nil then
    CharDBQuery('ALTER TABLE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` ADD COLUMN `starter_tickets_given` TINYINT(1) NOT NULL DEFAULT 0;')
    CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` SET `starter_tickets_given` = 1;')
end

if cc_enablePlayerLogs then
    CharDBQuery('CREATE TABLE IF NOT EXISTS `'..Config.customDbName..'`.`'..cc_playerLogsTable..'` ('
        ..'`source_name` VARCHAR(12) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL, '
        ..'`source_guid` INT(11) NOT NULL, '
        ..'`target_name` VARCHAR(12) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL, '
        ..'`target_guid` INT(11) DEFAULT NULL, '
        ..'`source_level` TINYINT UNSIGNED DEFAULT NULL, '
        ..'`tickets_before` INT(11) DEFAULT NULL, '
        ..'`tickets_after` INT(11) DEFAULT NULL, '
        ..'`status_code` TINYINT UNSIGNED NOT NULL COMMENT "0=FREE_CONFIG_TICKET,1=SUCCESS,2=FAILED", '
        ..'`reason` VARCHAR(255) DEFAULT NULL, '
        ..'`created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, '
        ..'KEY `idx_ccpl_source_guid` (`source_guid`), '
        ..'KEY `idx_ccpl_target_guid` (`target_guid`), '
        ..'KEY `idx_ccpl_status_code` (`status_code`), '
        ..'KEY `idx_ccpl_created_at` (`created_at`)'
        ..') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DEFAULT;'
    )
end

if cc_enableAdminLogs then
    CharDBQuery('CREATE TABLE IF NOT EXISTS `'..Config.customDbName..'`.`'..cc_adminLogsTable..'` ('
        ..'`source_name` VARCHAR(12) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL, '
        ..'`source_guid` INT(11) DEFAULT NULL, '
        ..'`target_name` VARCHAR(12) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL, '
        ..'`target_guid` INT(11) DEFAULT NULL, '
        ..'`target_level` TINYINT UNSIGNED DEFAULT NULL, '
        ..'`action_code` TINYINT UNSIGNED NOT NULL COMMENT "3=GM_ADD,4=GM_REMOVE,5=GM_LOOKUP,6=GM_RESTORE,7=GM_REVOKE,8=GM_CLEANUP,9=GM_MOVE", '
        ..'`tickets_before` INT(11) DEFAULT NULL, '
        ..'`tickets_after` INT(11) DEFAULT NULL, '
        ..'`status_code` TINYINT UNSIGNED NOT NULL COMMENT "1=SUCCESS,2=FAILED", '
        ..'`reason` VARCHAR(255) DEFAULT NULL, '
        ..'`created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, '
        ..'KEY `idx_ccal_source_guid` (`source_guid`), '
        ..'KEY `idx_ccal_target_guid` (`target_guid`), '
        ..'KEY `idx_ccal_action_code` (`action_code`), '
        ..'KEY `idx_ccal_status_code` (`status_code`), '
        ..'KEY `idx_ccal_created_at` (`created_at`)'
        ..') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DEFAULT;'
    )
end

local CC_STATUS_FREE_CONFIG_TICKET = 0
local CC_STATUS_SUCCESS = 1
local CC_STATUS_FAILED = 2
local CC_ACTION_GM_ADD = 3
local CC_ACTION_GM_REMOVE = 4
local CC_ACTION_GM_LOOKUP = 5
local CC_ACTION_GM_RESTORE = 6
local CC_ACTION_GM_REVOKE = 7
local CC_ACTION_GM_CLEANUP = 8
local CC_ACTION_GM_MOVE = 9

-- Every item mailed by a copy (or by a restore) with a snapshot of its enchants/gems/suffix, so an admin can re-send it.
-- A row with superseded_by_id set has been replaced by a restored copy and is no longer considered.
if cc_enableMailItemLog then
    CharDBQuery('CREATE TABLE IF NOT EXISTS `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` ('
        ..'`id` INT UNSIGNED NOT NULL AUTO_INCREMENT, '
        ..'`copy_id` INT UNSIGNED NOT NULL, '
        ..'`kind` VARCHAR(8) NOT NULL DEFAULT "copy" COMMENT "copy or restore", '
        ..'`source_guid` INT UNSIGNED DEFAULT NULL, '
        ..'`source_name` VARCHAR(12) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL, '
        ..'`target_guid` INT UNSIGNED NOT NULL, '
        ..'`target_name` VARCHAR(12) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL, '
        ..'`item_entry` INT UNSIGNED NOT NULL, '
        ..'`source_item_guid` INT UNSIGNED DEFAULT NULL COMMENT "item on the source character it was copied from", '
        ..'`item_guid` INT UNSIGNED NOT NULL COMMENT "the mailed item", '
        ..'`mail_id` INT UNSIGNED DEFAULT NULL, '
        ..'`creator_guid` INT UNSIGNED NOT NULL DEFAULT 0, '
        ..'`duration` INT NOT NULL DEFAULT 0, '
        ..'`charges` VARCHAR(255) NOT NULL DEFAULT "", '
        ..'`flags` INT UNSIGNED NOT NULL DEFAULT 0, '
        ..'`enchantments` TEXT NOT NULL, '
        ..'`random_property_id` SMALLINT NOT NULL DEFAULT 0, '
        ..'`restored_from_id` INT UNSIGNED DEFAULT NULL, '
        ..'`superseded_by_id` INT UNSIGNED DEFAULT NULL, '
        ..'`restored_by` VARCHAR(32) DEFAULT NULL, '
        ..'`revoked_at` TIMESTAMP NULL DEFAULT NULL, '
        ..'`revoked_by` VARCHAR(32) DEFAULT NULL, '
        ..'`created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, '
        ..'PRIMARY KEY (`id`), '
        ..'KEY `idx_ccmi_target_guid` (`target_guid`), '
        ..'KEY `idx_ccmi_item_guid` (`item_guid`), '
        ..'KEY `idx_ccmi_copy_id` (`copy_id`)'
        ..') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DEFAULT;'
    )
    -- tables created before .carboncopy revoke existed: add its columns
    for _, column in ipairs({ { "revoked_at", "TIMESTAMP NULL DEFAULT NULL" }, { "revoked_by", "VARCHAR(32) DEFAULT NULL" } }) do
        if CharDBQuery("SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '"..Config.customDbName.."' AND TABLE_NAME = '"
            ..cc_mailItemsTable.."' AND COLUMN_NAME = '"..column[1].."' LIMIT 1;") == nil then
            CharDBQuery('ALTER TABLE `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` ADD COLUMN `'..column[1]..'` '..column[2]..';')
        end
    end
end

local function cc_sqlQuote(value)
    if value == nil then
        return "NULL"
    end

    local escaped = tostring(value):gsub("\\", "\\\\"):gsub("'", "''")
    return "'"..escaped.."'"
end

-- Most tickets an account can hold. Adding is refused when the new total would go over it.
local CC_MAX_TICKETS = 1000

-- A ticket amount from a command: a whole number from 0 to 1000.
local function cc_validTicketAmount(text)
    local amount = tonumber(text)
    return amount ~= nil and amount == math.floor(amount) and amount >= 0 and amount <= 1000
end


-- Realm lists as sets (new balances, tickets move): { all = true } for -1, otherwise { ["1"] = true, ["2"] = true }.
local function cc_realmSet(list)
    if list == "-1" then
        return { all = true }
    end
    local set = {}
    for id in list:gmatch("%S+") do
        set[id] = true
    end
    return set
end

local function cc_realmsOverlap(a, b)
    if a.all or b.all then
        return true
    end
    for id in pairs(a) do
        if b[id] then
            return true
        end
    end
    return false
end

-- every realm of a is also in b
local function cc_realmsInside(a, b)
    if b.all then
        return true
    end
    if a.all then
        return false
    end
    for id in pairs(a) do
        if not b[id] then
            return false
        end
    end
    return true
end

-- Creates the balance this realm uses for an account that has none yet, with Config.ticketRealms as its realm list.
-- Starter tickets are per account: only an account without any balance row gets Config.freeTickets, an account that
-- already has a balance for other realms starts at 0 here. Returns true when it gave the starter tickets.
local function cc_createBalanceRow(accountId)
    local T = '`'..Config.customDbName..'`.`'..cc_carboncopyTable..'`'
    if CharDBQuery('SELECT 1 FROM '..T..' WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;') ~= nil then
        return false
    end
    -- Config.ticketRealms may overlap a balance the account already has for other realms (realm 1 uses "-1", the
    -- account has a "2" balance from realm 2): then the new balance gets only this realm, so no realm sees two.
    local list, fresh = CC_TICKET_REALMS, true
    local others = CharDBQuery('SELECT `realm_ids` FROM '..T..' WHERE `account_id` = '..accountId..';')
    if others ~= nil then
        fresh = false
        local mineSet = cc_realmSet(CC_TICKET_REALMS)
        repeat
            if cc_realmsOverlap(cc_realmSet(others:GetString(0)), mineSet) then
                list = tostring(CC_REALM_ID)
            end
        until not others:NextRow()
    end
    CharDBQuery('INSERT IGNORE INTO '..T..' (`account_id`, `tickets`, `allow_copy_from_id`, `starter_tickets_given`, `realm_ids`) '
        ..'VALUES ('..accountId..', '..(fresh and Config.freeTickets or 0)..', 0, 1, \''..list..'\');')
    return fresh
end

-- Adds tickets to (negative: removes them from) what the account has, in one statement, so a copy or another
-- grant running at the same moment is never overwritten. An account that never used .carboncopy has no row yet;
-- it owns the starter tickets (Config.freeTickets) it would get on its first use, so the change goes on top of those.
local function cc_changeTickets(accountId, delta)
    cc_createBalanceRow(accountId)
    CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` SET `tickets` = `tickets` + ('..delta..') '
        ..'WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..';')
end

local function cc_sqlNumber(value)
    if value == nil then
        return "NULL"
    end
    return tostring(value)
end

local function cc_logPlayer(sourceName, sourceGuid, targetName, targetGuid, sourceLevel, ticketsBefore, ticketsAfter, statusCode, reason)
    if not cc_enablePlayerLogs then
        return
    end

    CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_playerLogsTable..'` ('
        ..'`source_name`, `source_guid`, `target_name`, `target_guid`, `source_level`, '
        ..'`tickets_before`, `tickets_after`, `status_code`, `reason`'
        ..') VALUES ('
        ..cc_sqlQuote(sourceName)..', '
        ..cc_sqlNumber(sourceGuid)..', '
        ..cc_sqlQuote(targetName)..', '
        ..cc_sqlNumber(targetGuid)..', '
        ..cc_sqlNumber(sourceLevel)..', '
        ..cc_sqlNumber(ticketsBefore)..', '
        ..cc_sqlNumber(ticketsAfter)..', '
        ..cc_sqlNumber(statusCode)..', '
        ..cc_sqlQuote(reason)
        ..');'
    )
end

-- Gives an account its starter tickets (Config.freeTickets) once: when it has no ticket row yet, or a row that
-- something else created without them (starter_tickets_given = 0, e.g. tickets credited by a website). Returns true if
-- it granted them. who / reason only go to the player log.
local function cc_ensureStarterTickets(accountId, who, reason)
    local q = CharDBQuery('SELECT `starter_tickets_given` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;')
    if q ~= nil and q:GetUInt8(0) ~= 0 then
        return false
    end
    if q == nil then
        if not cc_createBalanceRow(accountId) then
            return false   -- the account already has a balance for other realms: no second set of starter tickets
        end
    elseif CharDBQuery('SELECT 1 FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId
        ..' AND `starter_tickets_given` = 1 AND NOT '..CC_MY_BALANCE_SQL..' LIMIT 1;') ~= nil then
        -- starter tickets are per account and another balance already had them: only mark this one
        CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` SET `starter_tickets_given` = 1 WHERE `account_id` = '
            ..accountId..' AND '..CC_MY_BALANCE_SQL..' AND `starter_tickets_given` = 0;')
        return false
    else
        CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` SET `tickets` = GREATEST(`tickets`, LEAST(`tickets` + '
            ..Config.freeTickets..', '..CC_MAX_TICKETS..')), `starter_tickets_given` = 1 WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' AND `starter_tickets_given` = 0;')
    end
    cc_logPlayer(who and who:GetName() or "console", who and tonumber(tostring(who:GetGUID())) or nil, nil, nil,
        who and who:GetLevel() or nil, nil, nil, CC_STATUS_FREE_CONFIG_TICKET,
        (reason or "Starter tickets granted").." (account "..cc_accountLabel(accountId)..", +"..Config.freeTickets..")")
    return true
end

local function cc_logAdmin(sourceName, sourceGuid, targetName, targetGuid, targetLevel, actionCode, ticketsBefore, ticketsAfter, statusCode, reason)
    if not cc_enableAdminLogs then
        return
    end

    CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_adminLogsTable..'` ('
        ..'`source_name`, `source_guid`, `target_name`, `target_guid`, `target_level`, '
        ..'`action_code`, `tickets_before`, `tickets_after`, `status_code`, `reason`'
        ..') VALUES ('
        ..cc_sqlQuote(sourceName)..', '
        ..cc_sqlNumber(sourceGuid)..', '
        ..cc_sqlQuote(targetName)..', '
        ..cc_sqlNumber(targetGuid)..', '
        ..cc_sqlNumber(targetLevel)..', '
        ..cc_sqlNumber(actionCode)..', '
        ..cc_sqlNumber(ticketsBefore)..', '
        ..cc_sqlNumber(ticketsAfter)..', '
        ..cc_sqlNumber(statusCode)..', '
        ..cc_sqlQuote(reason)
        ..');'
    )
end

local function cc_sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        table.insert(keys, key)
    end

    table.sort(keys, function(a, b)
        local typeA = type(a)
        local typeB = type(b)
        if typeA == typeB then
            if typeA == "number" then
                return a < b
            end
            return tostring(a) < tostring(b)
        end

        return typeA < typeB
    end)

    return keys
end

local function cc_sendTableDump(chatHandler, title, tbl)
    chatHandler:SendSysMessage(title)
    for _, key in ipairs(cc_sortedKeys(tbl)) do
        chatHandler:SendSysMessage("  ["..tostring(key).."] = "..tostring(tbl[key]))
    end
end

local function cc_formatDisplayValue(value)
    if type(value) ~= "string" then
        return tostring(value)
    end

    local compact = value:gsub("%s+", " ")
    compact = compact:gsub("^%s+", "")
    compact = compact:gsub("%s+$", "")
    return compact
end

local function cc_execConfigCommand(chatHandler)
    chatHandler:SendSysMessage(cc_t(nil, "CONFIG_HEADER"))

    for _, key in ipairs(cc_sortedKeys(Config)) do
        local value = Config[key]
        if type(value) ~= "table" then
            local note = ""
            if key == "mailItemLogRetentionDays" then
                -- what is in effect (-1 follows the mails; an invalid value uses the fallback)
                note = " (in effect: "..(cc_mailLogRetentionDays > 0 and cc_mailLogRetentionDays.." days" or "never deleted")
                    ..(cc_validRetention(value) and "" or ", from the fallback")..")"
            end
            chatHandler:SendSysMessage("  "..tostring(key).." = "..cc_formatDisplayValue(value)..note)
        end
    end

    cc_sendTableDump(chatHandler, "  cc_maps:", cc_maps)
    cc_sendTableDump(chatHandler, "  ticket_Cost:", ticket_Cost)

    chatHandler:SendSysMessage(cc_t(nil, "CONFIG_FOOTER"))
end

-- cc_execLogsCommand: shared handler for ".carboncopy logs" from console or GM.
local function cc_execLogsCommand(chatHandler, commandArray, startIdx)
    -- Help subcommand
    local firstArg = commandArray[startIdx] and string.lower(commandArray[startIdx]) or nil
    if firstArg == "help" or firstArg == "--help" then
        for _, line in ipairs(L.LOGS_HELP[0]) do
            chatHandler:SendSysMessage(line)
        end
        return
    end

    local filterSource  = nil
    local filterTarget  = nil
    local filterDay     = nil
    local filterCode    = nil
    local limitN        = 20
    local orderOldest   = false
    local parseError    = false

    local i = startIdx
    while i <= #commandArray do
        local flag = string.lower(commandArray[i])
        if flag == "--source" then
            i = i + 1
            if commandArray[i] ~= nil then filterSource = commandArray[i] end
        elseif flag == "--target" then
            i = i + 1
            if commandArray[i] ~= nil then filterTarget = commandArray[i] end
        elseif flag == "--day" then
            i = i + 1
            if commandArray[i] ~= nil then filterDay = commandArray[i] end
        elseif flag == "--code" then
            i = i + 1
            if commandArray[i] ~= nil then
                local n = tonumber(commandArray[i])
                if n ~= nil and n >= 0 then
                    filterCode = math.floor(n)
                else
                    chatHandler:SendSysMessage(cc_t(nil, "LOGS_BAD_CODE"))
                end
            end
        elseif flag == "--limit" then
            i = i + 1
            if commandArray[i] ~= nil then
                local n = tonumber(commandArray[i])
                if n ~= nil and n >= 1 and n <= 100 then
                    limitN = math.floor(n)
                else
                    chatHandler:SendSysMessage(cc_t(nil, "LOGS_BAD_LIMIT"))
                end
            end
        elseif flag == "--oldest" then
            orderOldest = true
        else
            chatHandler:SendSysMessage(cc_t(nil, "LOGS_UNKNOWN_FLAG", commandArray[i]))
            parseError = true
            break
        end
        i = i + 1
    end

    if parseError then
        return
    end

    local conditions = {}

    if filterSource ~= nil then
        if tonumber(filterSource) ~= nil then
            table.insert(conditions, '`source_guid` = '..math.floor(tonumber(filterSource)))
        else
            table.insert(conditions, '`source_name` = '..cc_sqlQuote(cc_normalizeCharacterName(filterSource)))
        end
    end

    if filterTarget ~= nil then
        if tonumber(filterTarget) ~= nil then
            table.insert(conditions, '`target_guid` = '..math.floor(tonumber(filterTarget)))
        else
            table.insert(conditions, '`target_name` = '..cc_sqlQuote(cc_normalizeCharacterName(filterTarget)))
        end
    end

    if filterDay ~= nil then
        if filterDay:match("^%d%d%d%d%-%d%d%-%d%d$") then
            table.insert(conditions, 'DATE(`created_at`) = '..cc_sqlQuote(filterDay))
        else
            chatHandler:SendSysMessage(cc_t(nil, "LOGS_BAD_DAY"))
        end
    end

    if filterCode ~= nil then
        table.insert(conditions, '`status_code` = '..filterCode)
    end

    local whereClause = (#conditions > 0) and (" WHERE "..table.concat(conditions, " AND ")) or ""
    local orderDir    = orderOldest and "ASC" or "DESC"

    local sql = 'SELECT `source_name`,`source_guid`,`source_level`,`target_name`,`target_guid`,'
        ..'`tickets_before`,`tickets_after`,`status_code`,`reason`,`created_at`'
        ..' FROM `'..Config.customDbName..'`.`'..cc_playerLogsTable..'`'
        ..whereClause
        ..' ORDER BY `created_at` '..orderDir
        ..' LIMIT '..limitN..';'

    -- Build active-filter summary for header
    local activeFilters = {}
    if filterSource ~= nil then table.insert(activeFilters, "source:"..filterSource) end
    if filterTarget ~= nil then table.insert(activeFilters, "target:"..filterTarget) end
    if filterDay    ~= nil then table.insert(activeFilters, "day:"..filterDay) end
    if filterCode   ~= nil then table.insert(activeFilters, "code:"..filterCode) end
    local filterSummary = (#activeFilters > 0) and table.concat(activeFilters, "  ") or "none"

    -- Header
    chatHandler:SendSysMessage(cc_t(nil, "LOGS_TITLE"))
    chatHandler:SendSysMessage(cc_t(nil, "LOGS_FILTERS", filterSummary, limitN, cc_t(nil, orderOldest and "LOGS_OLDEST_FIRST" or "LOGS_NEWEST_FIRST")))
    chatHandler:SendSysMessage(cc_t(nil, "LOGS_COLUMNS"))
    chatHandler:SendSysMessage(cc_t(nil, "LOGS_RULE"))

    local rows = CharDBQuery(sql)
    if rows == nil then
        chatHandler:SendSysMessage(cc_t(nil, "LOGS_NONE"))
        chatHandler:SendSysMessage(cc_t(nil, "LOGS_END"))
        return
    end

    local count = 0
    repeat
        local sName     = rows:GetString(0)
        local sGuid     = rows:GetUInt32(1)
        local sLevel    = rows:GetUInt8(2)
        local tName     = rows:GetString(3)
        local tGuid     = rows:GetUInt32(4)
        local tickBef   = rows:GetInt32(5)
        local tickAft   = rows:GetInt32(6)
        local reason    = rows:GetString(8)
        local createdAt = rows:GetString(9)

        -- Shorten timestamp to "YYYY-MM-DD HH:MM" from "YYYY-MM-DD HH:MM:SS"
        local timeStr = createdAt:sub(1, 16)

        local srcPart = sName.." (GUID: "..sGuid..") [lv"..sLevel.."]"

        local tgtPart = ""
        if tName ~= nil and tName ~= "" then
            tgtPart = " | "..tName.." (GUID: "..tGuid..")"
        end

        local tickPart
        if tickBef == tickAft then
            tickPart = tostring(tickBef)
        else
            tickPart = tickBef.." => "..tickAft
        end

        local statusCode = rows:GetUInt8(7)
        local reasonPart = reason.." (Code: "..statusCode..")"

        chatHandler:SendSysMessage(timeStr.." | "..srcPart..tgtPart.." | "..tickPart.." | "..reasonPart)
        count = count + 1
    until not rows:NextRow()

    chatHandler:SendSysMessage(cc_t(nil, "LOGS_RULE"))
    chatHandler:SendSysMessage(cc_t(nil, "LOGS_SUMMARY", count, limitN, cc_t(nil, orderOldest and "LOGS_OLDEST_FIRST" or "LOGS_NEWEST_FIRST")))
    chatHandler:SendSysMessage(cc_t(nil, "LOGS_END"))
end

-- Ticket cost to copy a character of this level, or nil if no ticket_Cost bracket covers it.
local function cc_ticketCostForLevel(level)
    if Config.ticketCost == "single" then
        return 1
    end
    local highest = 0
    for bracket in pairs(ticket_Cost) do
        if bracket > highest then
            highest = bracket
        end
    end
    for n = level, highest do
        if ticket_Cost[n] ~= nil then
            return ticket_Cost[n]
        end
    end
    return nil
end

-- Sends the ticket cost per level (only levels that can be copied) and the starter tickets.
local function cc_sendTicketCosts(player, chatHandler)
    chatHandler:SendSysMessage(cc_info(player, "COSTS_HEADER"))
    if Config.ticketCost == "single" then
        chatHandler:SendSysMessage(cc_info(player, "COST_SINGLE"))
    else
        local brackets = {}
        for bracket in pairs(ticket_Cost) do
            table.insert(brackets, bracket)
        end
        table.sort(brackets)
        local from = 1
        for _, to in ipairs(brackets) do
            if from > Config.maxLevel then
                break
            end
            local upTo = math.min(to, Config.maxLevel)
            if from == upTo then
                chatHandler:SendSysMessage(cc_info(player, "COST_LEVEL", from, ticket_Cost[to]))
            else
                chatHandler:SendSysMessage(cc_info(player, "COST_RANGE", from, upTo, ticket_Cost[to]))
            end
            from = to + 1
        end
    end
    chatHandler:SendSysMessage(cc_info(player, "STARTER_TICKETS", Config.freeTickets))
end

------------------------------------------
-- Mail expiry / mailed-items log / restore
------------------------------------------

-- expire_time to put on CarbonCopy mails, or nil to leave the core default (30 days).
local function cc_mailExpireTime()
    if cc_mailExpireDays < 0 then
        return nil
    end
    if cc_mailExpireDays == 0 then
        return CC_MAIL_NEVER_EXPIRES
    end
    return math.min(os.time() + cc_mailExpireDays * 86400, CC_MAIL_NEVER_EXPIRES)
end

-- Pushes the expiry of every mail (to this receiver) that holds one of these items.
local function cc_extendMailForItems(receiverGuid, itemGuids)
    local expire = cc_mailExpireTime()
    if expire == nil or #itemGuids == 0 then
        return
    end
    CharDBQuery('UPDATE `mail` AS m INNER JOIN `mail_items` AS mi ON mi.mail_id = m.id '
        ..'SET m.expire_time = '..expire..' '
        ..'WHERE m.receiver = '..receiverGuid..' AND mi.item_guid IN ('..table.concat(itemGuids, ',')..');')
end

-- Lifts the temporary lock the script put on a character (never touches other bans).
-- The core only checks character_banned.active at login, so this unlocks immediately.
-- Locks a character out (login is refused while it has an active character_banned row) and kicks it if online.
-- Written directly and synchronously instead of with Ban(): the core's BanCharacter first deactivates every other
-- ban on the character (a real ban would be lost), and it writes asynchronously (a lift right after could miss it).
-- The row expires on its own after CC_LOCK_SECONDS in case the script never lifts it.
local function cc_lockCharacter(characterGuid, reason, by)
    -- The key is (guid, bandate): a lock lifted earlier in the same second leaves an inactive row with that key, which
    -- is re-activated instead of silently skipping the new lock. A real ban on that key is never changed
    -- (banreason is assigned last, so the IF()s still see the old reason).
    local ours = '`banreason` IN ('..cc_sqlQuote(CC_BAN_REASON_COPY)..', '..cc_sqlQuote(CC_BAN_REASON_RESTORE)..', '..cc_sqlQuote(CC_BAN_REASON_REVOKE)..')'
    CharDBQuery('INSERT INTO `character_banned` (`guid`, `bandate`, `unbandate`, `bannedby`, `banreason`, `active`) VALUES ('
        ..characterGuid..', UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + '..CC_LOCK_SECONDS..', '..cc_sqlQuote(string.sub(tostring(by), 1, 50))
        ..', '..cc_sqlQuote(reason)..', 1) ON DUPLICATE KEY UPDATE '
        ..'`active` = IF('..ours..', 1, `active`), '
        ..'`unbandate` = IF('..ours..', VALUES(`unbandate`), `unbandate`), '
        ..'`banreason` = IF('..ours..', VALUES(`banreason`), `banreason`);')
    local online = GetPlayerByGUID(characterGuid)
    if online ~= nil then
        online:KickPlayer()
    end
end

-- Lifts the lock the script put on a character. Only rows with this script's reason are touched, never other bans.
-- reason: one of the CC_BAN_REASON_* (nil = all three).
local function cc_liftCarbonCopyBan(characterGuid, reason)
    if characterGuid == nil or characterGuid == 0 then
        return
    end
    local reasons
    if reason ~= nil then
        reasons = cc_sqlQuote(reason)
    else
        reasons = cc_sqlQuote(CC_BAN_REASON_COPY)..', '..cc_sqlQuote(CC_BAN_REASON_RESTORE)..', '..cc_sqlQuote(CC_BAN_REASON_REVOKE)
    end
    CharDBQuery('UPDATE `character_banned` SET `active` = 0 WHERE `guid` = '..characterGuid..' AND `active` = 1 '
        ..'AND `banreason` IN ('..reasons..');')
end

-- Column names of a characters-database table, in order (read once from information_schema).
local cc_columnCache = {}
local function cc_tableColumns(tableName)
    if cc_columnCache[tableName] == nil then
        local columns = {}
        local q = CharDBQuery("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '"
            ..tableName.."' ORDER BY ORDINAL_POSITION;")
        if q ~= nil then
            repeat
                table.insert(columns, q:GetString(0))
            until not q:NextRow()
        end
        cc_columnCache[tableName] = columns
    end
    return cc_columnCache[tableName]
end

-- Copies the rows of tableName matching whereSql into the same table in one INSERT ... SELECT, with some columns
-- replaced (overrides: column = value). One statement on one connection, so it works with any SynchThreads setting
-- (the old temporary tables only existed on the connection that created them). targetWhereSql selects the copied
-- rows; if fewer arrive than the source has, it raises an error so the copy stops (and refunds) instead of going on.
local function cc_copyRows(tableName, whereSql, overrides, targetWhereSql)
    local columns = cc_tableColumns(tableName)
    if #columns == 0 then
        error("no columns found for table "..tableName)
    end
    local names, values = {}, {}
    for _, column in ipairs(columns) do
        table.insert(names, '`'..column..'`')
        if overrides[column] ~= nil then
            table.insert(values, tostring(tonumber(overrides[column])))
        else
            table.insert(values, '`'..column..'`')
        end
    end
    CharDBQuery('INSERT INTO `'..tableName..'` ('..table.concat(names, ', ')..') SELECT '..table.concat(values, ', ')
        ..' FROM `'..tableName..'` WHERE '..whereSql..';')
    -- CharDBQuery only logs a failed statement, so compare row counts to catch it and stop the copy
    local source = CharDBQuery('SELECT 1 FROM `'..tableName..'` WHERE '..whereSql..';')
    local target = CharDBQuery('SELECT 1 FROM `'..tableName..'` WHERE '..targetWhereSql..';')
    local sourceCount = source ~= nil and source:GetRowCount() or 0
    local targetCount = target ~= nil and target:GetRowCount() or 0
    if targetCount < sourceCount then
        error("copying "..tableName.." failed ("..targetCount.." of "..sourceCount.." rows), see the SQL error in the server log")
    end
end

local function cc_itemExists(entry)
    return entry ~= nil and WorldDBQuery('SELECT 1 FROM `item_template` WHERE `entry` = '..entry..' LIMIT 1;') ~= nil
end

-- Mails one of each entry to the receiver, 12 items per mail (GM stationery).
-- Returns the new item guids in the same order as entries (nil where a mail failed), mails sent, mails failed.
local function cc_sendItemMails(receiverGuid, subject, body, entries)
    local guids = {}
    local sent, failed = 0, 0
    local first = 1
    while first <= #entries do
        local last = math.min(first + 11, #entries)
        local args = { subject, body, receiverGuid, 0, 61, 0, 0, 0 }
        for n = first, last do
            table.insert(args, entries[n])
            table.insert(args, 1)
        end
        local result = { pcall(SendMail, cc_unpack(args)) }
        if result[1] then
            sent = sent + 1
            for n = first, last do
                guids[n] = result[n - first + 2]
            end
        else
            failed = failed + 1
            PrintError("CarbonCopy: SendMail to "..receiverGuid.." failed: "..tostring(result[2]))
        end
        first = last + 1
    end
    return guids, sent, failed
end

-- SendMail commits asynchronously: true once every item is visible in mail_items.
local function cc_mailItemsCommitted(itemGuids)
    if #itemGuids == 0 then
        return true
    end
    local q = CharDBQuery('SELECT `item_guid` FROM `mail_items` WHERE `item_guid` IN ('..table.concat(itemGuids, ',')..');')
    return q ~= nil and q:GetRowCount() >= #itemGuids
end

local function cc_characterNameByGuid(guid)
    if guid == nil then
        return nil
    end
    local q = CharDBQuery('SELECT `name` FROM `characters` WHERE `guid` = '..guid..' LIMIT 1;')
    if q == nil then
        return nil
    end
    return q:GetString(0)
end

-- Item link in game, "Name (entry)" on the console.
local function cc_itemLabel(player, entry)
    if player ~= nil and GetItemLink ~= nil then
        return GetItemLink(entry, player:GetDbcLocale())
    end
    local q = WorldDBQuery('SELECT `name` FROM `item_template` WHERE `entry` = '..entry..' LIMIT 1;')
    if q ~= nil then
        return q:GetString(0).." ("..entry..")"
    end
    return "item "..entry
end

-- Snapshots the mailed item (as it is in item_instance right now) into the mailed-items log.
local function cc_logMailedItem(copyId, kind, sourceGuid, sourceName, targetGuid, targetName, sourceItemGuid, itemGuid, restoredFromId, restoredBy)
    if not cc_enableMailItemLog or itemGuid == nil then
        return
    end
    CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` ('
        ..'`copy_id`, `kind`, `source_guid`, `source_name`, `target_guid`, `target_name`, `item_entry`, `source_item_guid`, '
        ..'`item_guid`, `mail_id`, `creator_guid`, `duration`, `charges`, `flags`, `enchantments`, `random_property_id`, '
        ..'`restored_from_id`, `restored_by`) '
        ..'SELECT '..copyId..', '..cc_sqlQuote(kind)..', '..cc_sqlNumber(sourceGuid)..', '..cc_sqlQuote(sourceName)..', '
        ..targetGuid..', '..cc_sqlQuote(targetName or "?")..', ii.itemEntry, '..cc_sqlNumber(sourceItemGuid)..', '
        ..'ii.guid, (SELECT mi.mail_id FROM `mail_items` AS mi WHERE mi.item_guid = ii.guid LIMIT 1), '
        ..'ii.creatorGuid, ii.duration, COALESCE(ii.charges, SPACE(0)), COALESCE(ii.flags, 0), ii.enchantments, ii.randomPropertyId, '
        ..cc_sqlNumber(restoredFromId)..', '..cc_sqlQuote(restoredBy)..' '
        ..'FROM `item_instance` AS ii WHERE ii.guid = '..itemGuid..';')
end

-- Deletes mailed-items log rows older than `days` days. Returns how many were deleted.
local function cc_cleanupMailLog(days)
    local logTable = '`'..Config.customDbName..'`.`'..cc_mailItemsTable..'`'
    local where = ' WHERE `created_at` < NOW() - INTERVAL '..math.floor(days)..' DAY'
    local q = CharDBQuery('SELECT `id` FROM '..logTable..where..';')
    local count = q ~= nil and q:GetRowCount() or 0
    if count > 0 then
        CharDBQuery('DELETE FROM '..logTable..where..';')
    end
    return count
end

local function cc_nextCopyId()
    local q = CharDBQuery('SELECT MAX(`copy_id`) FROM `'..Config.customDbName..'`.`'..cc_mailItemsTable..'`;')
    if q == nil or q:IsNull(0) then
        return 1
    end
    return q:GetUInt32(0) + 1
end

-- Where a logged item is now. Returns isMissing, location key (CarbonCopy_Locale.lua LOC_*), optional value for it.
-- Anything still owned by the target (bags, bank, keyring, mailbox, auction) or still existing elsewhere
-- (guild bank, another character) is NOT missing; only items that no longer exist (or are lost) are.
local function cc_locateMailedItem(itemGuid, targetGuid)
    local q = CharDBQuery('SELECT `guid`, `bag`, `slot` FROM `character_inventory` WHERE `item` = '..itemGuid..' LIMIT 1;')
    if q ~= nil then
        local owner, bag, slot = q:GetUInt32(0), q:GetUInt32(1), q:GetUInt8(2)
        if owner ~= targetGuid then
            return false, "LOC_OTHER_CHAR", cc_characterNameByGuid(owner) or tostring(owner)
        end
        if bag == 0 then
            if slot < 19 then return false, "LOC_EQUIPPED" end
            if slot < 23 then return false, "LOC_EQUIPPED_BAG" end
            if slot < 39 then return false, "LOC_BACKPACK" end
            if slot < 67 then return false, "LOC_BANK" end
            if slot < 74 then return false, "LOC_BANK_BAG_SLOT" end
            if slot >= 86 and slot < 118 then return false, "LOC_KEYRING" end
            return false, "LOC_INVENTORY"
        end
        local p = CharDBQuery('SELECT `slot` FROM `character_inventory` WHERE `item` = '..bag..' LIMIT 1;')
        if p ~= nil and p:GetUInt8(0) >= 67 and p:GetUInt8(0) < 74 then
            return false, "LOC_BANK_IN_BAG"
        end
        return false, "LOC_BAGS"
    end

    q = CharDBQuery('SELECT `mail_id`, `receiver` FROM `mail_items` WHERE `item_guid` = '..itemGuid..' LIMIT 1;')
    if q ~= nil then
        local mailId, receiver = q:GetUInt32(0), q:GetUInt32(1)
        if receiver == targetGuid then
            return false, "LOC_MAILBOX", mailId
        end
        if receiver == 0 then
            return true, "LOC_MAIL_LOST"
        end
        return false, "LOC_MAIL_OTHER", cc_characterNameByGuid(receiver) or tostring(receiver)
    end

    if CharDBQuery('SELECT 1 FROM `auctionhouse` WHERE `itemguid` = '..itemGuid..' LIMIT 1;') ~= nil then
        return false, "LOC_AUCTION"
    end
    if CharDBQuery('SELECT 1 FROM `guild_bank_item` WHERE `item_guid` = '..itemGuid..' LIMIT 1;') ~= nil then
        return false, "LOC_GUILD_BANK"
    end
    if CharDBQuery('SELECT 1 FROM `item_instance` WHERE `guid` = '..itemGuid..' LIMIT 1;') ~= nil then
        return true, "LOC_ORPHANED"
    end
    return true, "LOC_GONE"
end

-- Tells the admin (in game, in their locale, if still online) and the server log (English) how a delayed restore went.
local function cc_notifyAdmin(adminGuid, key, ...)
    PrintInfo("CarbonCopy: "..cc_tl(0, key, ...))
    if adminGuid ~= nil then
        local admin = GetPlayerByGUID(adminGuid)
        if admin ~= nil then
            admin:SendBroadcastMessage(cc_t(admin, key, ...))
        end
    end
end

-- say(key, ...) sends a locale text: to a ChatHandler (in the player's locale) or, after a delay, via cc_notifyAdmin.
local function cc_chatSay(player, chatHandler)
    return function(key, ...)
        chatHandler:SendSysMessage(cc_t(player, key, ...))
    end
end

local function cc_sendRestoreSyntax(say)
    say("SYNTAX_RESTORE_LIST")
    say("SYNTAX_RESTORE_MISSING")
    say("SYNTAX_RESTORE_ALL")
    say("SYNTAX_RESTORE_KICK")
end

-- Writes enchants/gems/suffix back onto the restored items, keeps the mail, logs the new items, unlocks the character.
-- Runs a few seconds after SendMail so its transaction is committed; retries a few times if not yet.
local function cc_finishRestore(job)
    local newGuids = {}
    for _, pair in ipairs(job.pairs) do
        table.insert(newGuids, pair.newGuid)
    end

    if not cc_mailItemsCommitted(newGuids) then
        if job.attempts < CC_POLL_MAX then
            job.attempts = job.attempts + 1
            CreateLuaEvent(function() cc_finishRestore(job) end, CC_POLL_MS, 1)
            return
        end
        -- the mails never showed up in the database: nothing to patch or log, tell the admin instead of "done"
        cc_liftCarbonCopyBan(job.targetGuid, CC_BAN_REASON_RESTORE)
        cc_restoreBusy[job.targetGuid] = nil
        cc_notifyAdmin(job.adminGuid, "RESTORE_TIMEOUT", job.targetName)
        cc_logAdmin(job.adminName, job.adminGuid, job.targetName, job.targetGuid, nil, CC_ACTION_GM_RESTORE, nil, nil,
            CC_STATUS_FAILED, "Restore mails not saved in time, enchants not applied, nothing logged")
        return
    end

    for _, pair in ipairs(job.pairs) do
        local row = pair.row
        CharDBQuery('UPDATE `item_instance` SET `owner_guid` = '..job.targetGuid..', '
            ..'`creatorGuid` = '..row.creatorGuid..', `duration` = '..row.duration..', '
            ..'`charges` = '..cc_sqlQuote(row.charges)..', `flags` = '..cc_copyFlagsSql(row.flags)..', '
            ..'`enchantments` = '..cc_sqlQuote(row.enchantments)..', `randomPropertyId` = '..row.randomPropertyId..' '
            ..'WHERE `guid` = '..pair.newGuid..';')
    end

    cc_extendMailForItems(job.targetGuid, newGuids)

    for _, pair in ipairs(job.pairs) do
      local row = pair.row
      if job.clear then
        -- --clear: everything went fine, drop the restored item's log row and don't log the new copy
        CharDBQuery('DELETE FROM `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` WHERE `id` = '..row.id..';')
      else
        cc_logMailedItem(row.copyId, "restore", row.sourceGuid, row.sourceName, job.targetGuid, job.targetName,
            row.sourceItemGuid, pair.newGuid, row.id, job.adminName)
        local q = CharDBQuery('SELECT `id` FROM `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` '
            ..'WHERE `item_guid` = '..pair.newGuid..' ORDER BY `id` DESC LIMIT 1;')
        if q ~= nil then
            CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` SET `superseded_by_id` = '..q:GetUInt32(0)
                ..' WHERE `id` = '..row.id..';')
        end
      end
    end

    cc_liftCarbonCopyBan(job.targetGuid, CC_BAN_REASON_RESTORE)
    cc_restoreBusy[job.targetGuid] = nil
    cc_notifyAdmin(job.adminGuid, job.clear and "RESTORE_DONE_CLEARED" or "RESTORE_DONE", #job.pairs, job.targetName, job.mode, job.targetName)
    cc_logAdmin(job.adminName, job.adminGuid, job.targetName, job.targetGuid, nil, CC_ACTION_GM_RESTORE, nil, nil,
        CC_STATUS_SUCCESS, "Restored "..#job.pairs.." item(s), mode "..job.mode..(job.kicked and ", kicked" or "")..(job.clear and ", log cleared" or ""))
end

-- For restore / revoke: returns true when the caller must stop because the target is online.
-- Without 'kick' it says onlineKey. With 'kick' it locks (which kicks) the character, waits until its logout save is
-- done and calls rerun(notify) - notify(key, ...) reaches the admin later, the ChatHandler is gone by then.
local function cc_requireOffline(targetName, targetGuid, isOnline, kick, kicked, admin, say, banReason, onlineKey, kickingKey, timeoutKey, rerun)
    if not isOnline or kicked then
        return false
    end
    if not kick then
        say(onlineKey, targetName)
        return true
    end
    cc_lockCharacter(targetGuid, banReason, admin.name)
    say(kickingKey, targetName)
    local notify = function(key, ...) cc_notifyAdmin(admin.guid, key, ...) end
    local tries = 0
    local function waitOffline()
        tries = tries + 1
        local o = CharDBQuery('SELECT `online` FROM `characters` WHERE `guid` = '..targetGuid..' LIMIT 1;')
        local offline = GetPlayerByGUID(targetGuid) == nil and (o == nil or o:GetUInt8(0) == 0)
        if offline then
            rerun(notify)
        elseif tries < CC_POLL_MAX then
            CreateLuaEvent(waitOffline, CC_POLL_MS, 1)
        else
            notify(timeoutKey, targetName)
            cc_liftCarbonCopyBan(targetGuid, banReason)
        end
    end
    CreateLuaEvent(waitOffline, CC_POLL_MS, 1)
    return true
end

-- .carboncopy restore $name [list|missing|all] [copyId] [--kick] [--clear]   (GM or console)
-- --clear: once the restore went fine, delete the log rows of the restored items instead of logging the new copies.
-- say: function(key, ...) that delivers a locale text (see cc_chatSay / cc_notifyAdmin).
-- admin: { name, guid } of who ran it; kicked: true when re-run after the kick (character already locked).
local function cc_execRestoreCommand(player, say, commandArray, startIdx, admin, kicked)
    admin = admin or { name = player and player:GetName() or "console", guid = player and tonumber(tostring(player:GetGUID())) or nil }

    if not cc_enableMailItemLog then
        say("RESTORE_LOG_DISABLED")
        return
    end
    if commandArray[startIdx] == nil then
        cc_sendRestoreSyntax(say)
        return
    end

    local targetName = cc_normalizeCharacterName(commandArray[startIdx])
    local mode, copyFilter, kick, clear = "list", nil, false, false
    for n = startIdx + 1, startIdx + 4 do
        local token = commandArray[n] and string.lower(commandArray[n])
        if token == nil then
            break
        elseif token == "list" or token == "missing" or token == "all" then
            mode = token
        elseif token == "--kick" then
            kick = true
        elseif token == "--clear" then
            clear = true
        elseif token:match("^%d+$") and tonumber(token) <= 4294967295 then
            copyFilter = tonumber(token)
        else
            cc_sendRestoreSyntax(say)
            return
        end
    end

    local q = CharDBQuery("SELECT `guid`, `online`, `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(targetName).." LIMIT 1;")
    if q == nil then
        say("RESTORE_CHAR_NOT_FOUND", targetName)
        return
    end
    local targetGuid, targetOnline, targetAccount = q:GetUInt32(0), q:GetUInt8(1), q:GetUInt32(2)
    local isOnline = targetOnline ~= 0 or GetPlayerByGUID(targetGuid) ~= nil

    -- stop here without restoring; unlocks the character if we kicked/locked it
    local function abort(key, ...)
        say(key, ...)
        if kicked and not cc_restoreBusy[targetGuid] then
            cc_liftCarbonCopyBan(targetGuid, CC_BAN_REASON_RESTORE)
        end
    end

    if mode ~= "list" then
        if cc_restoreBusy[targetGuid] then
            abort("RESTORE_BUSY", targetName)
            return
        end
        if cc_requireOffline(targetName, targetGuid, isOnline, kick, kicked, admin, say, CC_BAN_REASON_RESTORE,
            "RESTORE_ONLINE", "RESTORE_KICKING", "RESTORE_NOT_OFFLINE",
            function(notify) cc_execRestoreCommand(nil, notify, commandArray, startIdx, admin, true) end) then
            return
        end
    end

    local sql = 'SELECT `id`, `copy_id`, `kind`, `item_entry`, `item_guid`, `creator_guid`, `duration`, `charges`, `flags`, '
        ..'`enchantments`, `random_property_id`, `source_guid`, COALESCE(`source_name`, SPACE(0)), `source_item_guid`, '
        ..'DATE_FORMAT(`created_at`, "%Y-%m-%d %H:%i") '
        ..'FROM `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` '
        ..'WHERE `target_guid` = '..targetGuid..' AND `superseded_by_id` IS NULL AND `revoked_at` IS NULL'
    if copyFilter ~= nil then
        sql = sql..' AND `copy_id` = '..copyFilter
    end
    q = CharDBQuery(sql..' ORDER BY `id`;')
    if q == nil then
        if copyFilter ~= nil then
            abort("RESTORE_NO_ITEMS_COPY", targetName, copyFilter)
        else
            abort("RESTORE_NO_ITEMS", targetName)
        end
        return
    end

    local rows = {}
    repeat
        local row = {
            id = q:GetUInt32(0), copyId = q:GetUInt32(1), kind = q:GetString(2), entry = q:GetUInt32(3),
            itemGuid = q:GetUInt32(4), creatorGuid = q:GetUInt32(5), duration = q:GetInt32(6), charges = q:GetString(7),
            flags = q:GetUInt32(8), enchantments = q:GetString(9), randomPropertyId = q:GetInt16(10),
            sourceGuid = (not q:IsNull(11)) and q:GetUInt32(11) or nil, sourceName = q:GetString(12),
            sourceItemGuid = (not q:IsNull(13)) and q:GetUInt32(13) or nil, createdAt = q:GetString(14),
        }
        if row.sourceName == "" then
            row.sourceName = nil
        end
        row.missing, row.whereKey, row.whereValue = cc_locateMailedItem(row.itemGuid, targetGuid)
        table.insert(rows, row)
    until not q:NextRow()

    if mode == "list" then
        local missingCount = 0
        say("RESTORE_LIST_HEADER", targetName, targetGuid)
        if isOnline then
            say("RESTORE_LIST_ONLINE", targetName)
        end
        for _, row in ipairs(rows) do
            local where
            if row.whereValue ~= nil then
                where = cc_t(player, row.whereKey, row.whereValue)
            else
                where = cc_t(player, row.whereKey)
            end
            if row.missing then
                missingCount = missingCount + 1
                where = cc_t(player, "RESTORE_MISSING", where)
            end
            say("RESTORE_LIST_ROW", row.id, row.copyId, row.kind, row.createdAt, cc_itemLabel(player, row.entry), where)
        end
        say("RESTORE_LIST_FOOTER", #rows, missingCount, targetName)
        return
    end

    local toRestore = {}
    local skippedUnknown = 0
    for _, row in ipairs(rows) do
        if mode == "all" or row.missing then
            if cc_itemExists(row.entry) then
                table.insert(toRestore, row)
            else
                skippedUnknown = skippedUnknown + 1
            end
        end
    end
    if skippedUnknown > 0 then
        say("RESTORE_SKIPPED_UNKNOWN", skippedUnknown)
    end
    if #toRestore == 0 then
        abort("RESTORE_NOTHING", targetName, mode)
        return
    end

    -- keep the character offline while the mail and enchants are written (lifted by cc_finishRestore)
    if not kicked then
        cc_lockCharacter(targetGuid, CC_BAN_REASON_RESTORE, admin.name)
    end

    -- the mail is in the target account's client language
    local mailLocale = 0
    local a = AuthDBQuery('SELECT `locale` FROM `account` WHERE `id` = '..targetAccount..' LIMIT 1;')
    if a ~= nil then
        mailLocale = a:GetUInt8(0)
    end

    local entries = {}
    for n, row in ipairs(toRestore) do
        entries[n] = row.entry
    end
    local guids = cc_sendItemMails(targetGuid, cc_tl(mailLocale, "MAIL_RESTORE_SUBJECT"),
        cc_tl(mailLocale, "MAIL_RESTORE_BODY", targetName, cc_mailSignature), entries)

    local job = { pairs = {}, attempts = 0, targetGuid = targetGuid, targetName = targetName,
        adminName = admin.name, adminGuid = admin.guid, mode = mode, kicked = kicked, clear = clear }
    for n, row in ipairs(toRestore) do
        if guids[n] ~= nil then
            table.insert(job.pairs, { row = row, newGuid = guids[n] })
        end
    end

    if #job.pairs == 0 then
        say("RESTORE_NONE_MAILED")
        cc_liftCarbonCopyBan(targetGuid, CC_BAN_REASON_RESTORE)
        return
    end

    cc_restoreBusy[targetGuid] = true
    say("RESTORE_MAILING", #job.pairs, targetName, mode, targetName)
    CreateLuaEvent(function() cc_finishRestore(job) end, CC_POLL_MS, 1)
end

-- Revoke only takes items that are still unclaimed in the target's mailbox. Anything the player already took out
-- of the mail is left alone (and reported).
local CC_REVOKABLE = { LOC_MAILBOX = true }

-- Deletes an unclaimed mailed item: its mail_items row, the item, and the mail itself once it is empty.
local function cc_deleteMailedItem(itemGuid, targetGuid)
    local m = CharDBQuery('SELECT `mail_id` FROM `mail_items` WHERE `item_guid` = '..itemGuid..' AND `receiver` = '..targetGuid..' LIMIT 1;')
    if m == nil then
        return
    end
    local mailId = m:GetUInt32(0)
    CharDBQuery('DELETE FROM `mail_items` WHERE `item_guid` = '..itemGuid..' AND `receiver` = '..targetGuid..';')
    CharDBQuery('DELETE FROM `item_instance` WHERE `guid` = '..itemGuid..';')
    if CharDBQuery('SELECT 1 FROM `mail_items` WHERE `mail_id` = '..mailId..' LIMIT 1;') == nil then
        CharDBQuery('DELETE FROM `mail` WHERE `id` = '..mailId..' AND `money` = 0 AND `cod` = 0;')
        CharDBQuery('UPDATE `mail` SET `has_items` = 0 WHERE `id` = '..mailId..';')
    end
end

-- .carboncopy cleanup $days   (GM or console): delete mailed-items log rows that are $days days old or older
local function cc_execCleanupCommand(player, say, daysArg)
    local days = tonumber(daysArg)
    if days == nil or days < 1 or days ~= math.floor(days) then
        say("SYNTAX_CLEANUP")
        return
    end
    local admin = player and player:GetName() or "console"
    local count = cc_cleanupMailLog(days)
    say("CLEANUP_DONE", count, days)
    cc_logAdmin(admin, player and tonumber(tostring(player:GetGUID())) or nil, nil, nil, nil, CC_ACTION_GM_CLEANUP, nil, nil,
        CC_STATUS_SUCCESS, "Deleted "..count.." mailed-items log row(s) older than "..days.." day(s)")
end

local function cc_sendRevokeSyntax(say)
    say("SYNTAX_REVOKE_LIST")
    say("SYNTAX_REVOKE_ALL")
    say("SYNTAX_REVOKE_ID")
    say("SYNTAX_REVOKE_OPTIONS")
    say("SYNTAX_CLEANUP")
end

-- .carboncopy revoke $name [all|#logId] [copyId] [--kick] [--clear]   (GM or console)
-- Takes back CarbonCopy items that are still unclaimed in the mailbox. Without all/#logId it only lists what would
-- happen. Their log rows are marked revoked (restore skips them); with --clear they are deleted instead.
local function cc_execRevokeCommand(player, say, commandArray, startIdx, admin, kicked)
    admin = admin or { name = player and player:GetName() or "console", guid = player and tonumber(tostring(player:GetGUID())) or nil }

    if not cc_enableMailItemLog then
        say("RESTORE_LOG_DISABLED")
        return
    end
    if commandArray[startIdx] == nil then
        cc_sendRevokeSyntax(say)
        return
    end

    local targetName = cc_normalizeCharacterName(commandArray[startIdx])
    local execute, copyFilter, logId, kick, purge = false, nil, nil, false, false
    for n = startIdx + 1, startIdx + 5 do
        local token = commandArray[n] and string.lower(commandArray[n])
        if token == nil then
            break
        elseif token == "all" then
            execute = true
        elseif token == "--kick" then
            kick = true
        elseif token == "--clear" then
            purge = true
        elseif token:match("^#%d+$") and tonumber(token:sub(2)) <= 4294967295 then
            logId = tonumber(token:sub(2))
            execute = true
        elseif token:match("^%d+$") and tonumber(token) <= 4294967295 then
            copyFilter = tonumber(token)
        else
            cc_sendRevokeSyntax(say)
            return
        end
    end

    local q = CharDBQuery("SELECT `guid`, `online` FROM `characters` WHERE `name` = "..cc_sqlQuote(targetName).." LIMIT 1;")
    if q == nil then
        say("RESTORE_CHAR_NOT_FOUND", targetName)
        return
    end
    local targetGuid, targetOnline = q:GetUInt32(0), q:GetUInt8(1)
    local isOnline = targetOnline ~= 0 or GetPlayerByGUID(targetGuid) ~= nil

    local function finish()
        if kicked and not cc_restoreBusy[targetGuid] then
            cc_liftCarbonCopyBan(targetGuid, CC_BAN_REASON_REVOKE)
        end
    end

    if execute then
        if cc_restoreBusy[targetGuid] then
            say("RESTORE_BUSY", targetName)
            finish()
            return
        end
        if cc_requireOffline(targetName, targetGuid, isOnline, kick, kicked, admin, say, CC_BAN_REASON_REVOKE,
            "REVOKE_ONLINE", "REVOKE_KICKING", "REVOKE_NOT_OFFLINE",
            function(notify) cc_execRevokeCommand(nil, notify, commandArray, startIdx, admin, true) end) then
            return
        end
    end

    local sql = 'SELECT `id`, `copy_id`, `kind`, `item_entry`, `item_guid`, DATE_FORMAT(`created_at`, "%Y-%m-%d %H:%i") '
        ..'FROM `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` '
        ..'WHERE `target_guid` = '..targetGuid..' AND `superseded_by_id` IS NULL AND `revoked_at` IS NULL'
    if copyFilter ~= nil then
        sql = sql..' AND `copy_id` = '..copyFilter
    end
    if logId ~= nil then
        sql = sql..' AND `id` = '..logId
    end
    q = CharDBQuery(sql..' ORDER BY `id`;')
    if q == nil then
        if copyFilter ~= nil then
            say("RESTORE_NO_ITEMS_COPY", targetName, copyFilter)
        else
            say("RESTORE_NO_ITEMS", targetName)
        end
        finish()
        return
    end

    local remove, gone, skip = {}, {}, {}
    local rows = {}
    repeat
        local row = { id = q:GetUInt32(0), copyId = q:GetUInt32(1), kind = q:GetString(2), entry = q:GetUInt32(3),
            itemGuid = q:GetUInt32(4), createdAt = q:GetString(5) }
        local missing, whereKey, whereValue = cc_locateMailedItem(row.itemGuid, targetGuid)
        row.whereKey, row.whereValue = whereKey, whereValue
        if CC_REVOKABLE[whereKey] then
            row.action = "remove"
            table.insert(remove, row)
        elseif missing then
            row.action = "gone"
            table.insert(gone, row)
        else
            row.action = "skip"
            table.insert(skip, row)
        end
        table.insert(rows, row)
    until not q:NextRow()

    if not execute then
        say("REVOKE_LIST_HEADER", targetName, targetGuid)
        if isOnline then
            say("RESTORE_LIST_ONLINE", targetName)
        end
        for _, row in ipairs(rows) do
            local where
            if row.whereValue ~= nil then
                where = cc_t(player, row.whereKey, row.whereValue)
            else
                where = cc_t(player, row.whereKey)
            end
            local actionKey = (row.action == "remove" and "REVOKE_ROW_REMOVE") or (row.action == "gone" and "REVOKE_ROW_GONE") or "REVOKE_ROW_SKIP"
            say("RESTORE_LIST_ROW", row.id, row.copyId, row.kind, row.createdAt, cc_itemLabel(player, row.entry), cc_t(player, actionKey, where))
        end
        say("REVOKE_LIST_FOOTER", #remove, #gone, #skip, targetName)
        return
    end

    if #remove == 0 and #gone == 0 then
        say("REVOKE_NOTHING", targetName, #skip)
        finish()
        return
    end

    for _, row in ipairs(remove) do
        cc_deleteMailedItem(row.itemGuid, targetGuid)
    end

    -- the log rows of taken and already-gone items: deleted (purge) or marked revoked so restore leaves them alone
    local ids = {}
    for _, row in ipairs(remove) do table.insert(ids, row.id) end
    for _, row in ipairs(gone) do table.insert(ids, row.id) end
    local logTable = '`'..Config.customDbName..'`.`'..cc_mailItemsTable..'`'
    if purge then
        CharDBQuery('DELETE FROM '..logTable..' WHERE `id` IN ('..table.concat(ids, ',')..');')
    else
        CharDBQuery('UPDATE '..logTable..' SET `revoked_at` = NOW(), `revoked_by` = '..cc_sqlQuote(admin.name)
            ..' WHERE `id` IN ('..table.concat(ids, ',')..');')
    end

    finish()
    say("REVOKE_DONE", #remove, targetName, #gone, #skip, cc_t(player, purge and "REVOKE_LOG_DELETED" or "REVOKE_LOG_MARKED"))
    cc_logAdmin(admin.name, admin.guid, targetName, targetGuid, nil, CC_ACTION_GM_REVOKE, nil, nil, CC_STATUS_SUCCESS,
        "Revoked "..#remove.." item(s), "..#gone.." already gone, "..#skip.." skipped"..(purge and ", log rows deleted" or "")
        ..(kicked and ", kicked" or "")..(logId and (", log #"..logId) or "")..(copyFilter and (", copy "..copyFilter) or ""))
end

-- Pet numbers for copied hunter pets. The core hands out pet numbers from its own counter (MAX(id) at startup, then +1
-- per new pet), so MAX(id)+1 from Lua can be handed out again by the core before the next restart. Copied pets instead
-- count DOWN from CC_PET_ID_CEILING: the core's counter is far below that until a restart, and after a restart it starts
-- above the ceiling (MAX(id)+1), so the two can never meet. Stays below 2^31.
local CC_PET_ID_CEILING = 1073741824
local CC_PET_ID_RANGE = 100000000

local function cc_newPetId()
    local id = CC_PET_ID_CEILING
    local q = CharDBQuery('SELECT MIN(`id`) FROM `character_pet` WHERE `id` > '..(CC_PET_ID_CEILING - CC_PET_ID_RANGE)
        ..' AND `id` <= '..CC_PET_ID_CEILING..';')
    if q ~= nil and not q:IsNull(0) then
        id = q:GetUInt32(0) - 1
    end
    -- skip numbers that still have leftover rows
    while CharDBQuery('SELECT 1 FROM `character_pet` WHERE `id` = '..id..' LIMIT 1;') ~= nil
        or CharDBQuery('SELECT 1 FROM `pet_spell` WHERE `guid` = '..id..' LIMIT 1;') ~= nil do
        id = id - 1
    end
    return id
end

-- Splits a command line into arguments; "quoted text" is one argument (".carboncopy tickets move "1 2" -1").
local function cc_splitQuotedArgs(text)
    local args, i, n = {}, 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == '"' then
            local close = text:find('"', i + 1, true) or (n + 1)
            table.insert(args, text:sub(i + 1, close - 1))
            i = close + 1
        else
            local stop = text:find("%s", i) or (n + 1)
            table.insert(args, text:sub(i, stop - 1))
            i = stop
        end
    end
    return args
end

-- The target of a tickets / restore / revoke command: "--account $accountName", "--character $name" or just "$name"
-- (a character). Returns kind ("account" / "character"), name, index of the next argument; nil when the name is missing.
local function cc_readTarget(args, idx)
    local flag = args[idx] and string.lower(args[idx])
    if flag == "--account" or flag == "--character" then
        if args[idx + 1] == nil then
            return nil
        end
        if flag == "--account" then
            return "account", string.upper(args[idx + 1]), idx + 2
        end
        return "character", cc_normalizeCharacterName(args[idx + 1]), idx + 2
    end
    if args[idx] == nil then
        return nil
    end
    return "character", cc_normalizeCharacterName(args[idx]), idx + 1
end

-- Account id of a cc_readTarget target (and the character's low GUID for a character), nil when it doesn't exist.
local function cc_targetAccountId(kind, name)
    if kind == "account" then
        local q = AuthDBQuery("SELECT `id` FROM `account` WHERE `username` = "..cc_sqlQuote(name).." LIMIT 1;")
        return q and q:GetUInt32(0) or nil
    end
    local q = CharDBQuery("SELECT `account`, `guid` FROM `characters` WHERE `name` = "..cc_sqlQuote(name).." LIMIT 1;")
    if q == nil then
        return nil
    end
    return q:GetUInt32(0), q:GetUInt32(1)
end

-- The account's balance for this realm's list; an account without a row owns the starter tickets.
local function cc_ticketBalance(accountId)
    local q = CharDBQuery('SELECT `tickets` FROM '..cc_ticketTableSql..' WHERE `account_id` = '..accountId
        ..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;')
    if q ~= nil then
        return q:GetInt32(0)
    end
    return Config.freeTickets
end

local function cc_sendTicketsMoveSyntax(say)
    say("SYNTAX_TICKETS_MOVE")
    say("SYNTAX_TICKETS_MOVE_ACCOUNT")
end

local function cc_sendTicketsSyntax(say)
    say("SYNTAX_TICKETS_LOOKUP")
    say("SYNTAX_TICKETS_ADD")
    say("SYNTAX_TICKETS_REMOVE")
    cc_sendTicketsMoveSyntax(say)
end

-- .carboncopy tickets move $fromRealms $toRealms   (GM or console)
-- Changes the realm list of every balance whose realm_ids is exactly $fromRealms to $toRealms: the row itself is
-- updated, no second row. Lists like Config.ticketRealms: -1, 1, or several in quotes "1 2 3". 0 is not a realm.
-- .carboncopy tickets move --account $accountName|--character $name $toRealms: the same for the one balance that
-- account uses on this realm.
-- If the account has other balances for realms in $toRealms, their tickets are added to the moved balance and those
-- rows are removed, so a realm never sees two balances. A balance that also covers realms outside $toRealms is left
-- alone (that account is reported and not moved).
local function cc_execTicketsMove(player, say, command)
    local args = cc_splitQuotedArgs(command)
    local fromArg, toArg, accountId, accountLabel, fromRaw
    local flag = args[4] and string.lower(args[4])
    if flag == "--account" or flag == "--character" then
        local kind, name, nextIdx = cc_readTarget(args, 4)
        if kind == nil or args[nextIdx] == nil or args[nextIdx + 1] ~= nil then
            cc_sendTicketsMoveSyntax(say)
            return
        end
        accountId = cc_targetAccountId(kind, name)
        if accountId == nil then
            say(kind == "account" and "TICKETS_ACCOUNT_NOT_FOUND" or "TICKETS_CHAR_NOT_FOUND")
            return
        end
        accountLabel = cc_accountLabel(accountId)
        -- with two balances for this realm (rows from an older version), prefer the one that isn't the target already,
        -- so the move merges them
        local toNorm = cc_parseTicketRealms(args[nextIdx])
        local mine = CharDBQuery('SELECT `realm_ids` FROM '..cc_ticketTableSql..' WHERE `account_id` = '..accountId
            ..' AND '..CC_MY_BALANCE_SQL..' ORDER BY `realm_ids` = '..cc_sqlQuote(toNorm or "")..', `realm_ids` LIMIT 1;')
        if mine == nil then
            say("TICKETS_MOVE_NONE_ACCOUNT", accountLabel, tostring(CC_REALM_ID))
            return
        end
        fromArg, toArg = mine:GetString(0), args[nextIdx]
        fromRaw = fromArg   -- as stored (a row edited by hand may be "2 1"), so the WHERE finds it
    else
        fromArg, toArg = args[4], args[5]
        if fromArg == nil or toArg == nil or args[6] ~= nil then
            cc_sendTicketsMoveSyntax(say)
            return
        end
    end
    local from, fromError = cc_parseTicketRealms(fromArg)
    local to, toError = cc_parseTicketRealms(toArg)
    if from == nil or to == nil or fromArg:match("^%s*$") or toArg:match("^%s*$") then
        say("TICKETS_MOVE_INVALID", (from == nil and fromError) or (to == nil and toError) or "empty realm list")
        cc_sendTicketsMoveSyntax(say)
        return
    end
    if from == to then
        say("TICKETS_MOVE_SAME", from)
        return
    end

    -- not while a copy runs: its ticket deduction targets this realm's balance and could miss the moved one
    if cc_scriptIsBusy ~= 0 then
        say("ERR_SERVER_BUSY")
        return
    end

    local fromSql, toSql = cc_sqlQuote(fromRaw or from), "'"..to.."'"
    local q = CharDBQuery('SELECT `account_id`, `tickets` FROM '..cc_ticketTableSql
        ..' WHERE `realm_ids` = '..fromSql..(accountId and (' AND `account_id` = '..accountId) or '')..';')
    if q == nil then
        if accountId then
            say("TICKETS_MOVE_NONE_ACCOUNT", accountLabel, from)
        else
            say("TICKETS_MOVE_NONE", from)
        end
        return
    end
    local rows = {}
    repeat
        table.insert(rows, { account = q:GetUInt32(0), tickets = q:IsNull(1) and 0 or q:GetInt32(1) })
    until not q:NextRow()

    local toSet = cc_realmSet(to)
    local count, failed, movedTickets = 0, 0, 0
    for _, row in ipairs(rows) do
        local acc = row.account
        local where = ' WHERE `account_id` = '..acc..' AND `realm_ids` = '
        -- the account's other balances that cover realms of the new list: merged into this one
        local merge, mergeTickets, mergeFlag, blockedBy = {}, 0, 0, nil
        local others = CharDBQuery('SELECT `realm_ids`, `tickets`, `starter_tickets_given` FROM '..cc_ticketTableSql
            ..' WHERE `account_id` = '..acc..' AND `realm_ids` <> '..fromSql..';')
        if others ~= nil then
            repeat
                local list = others:GetString(0)
                local set = cc_realmSet(list)
                if cc_realmsOverlap(set, toSet) then
                    if cc_realmsInside(set, toSet) then
                        table.insert(merge, "'"..list.."'")
                        mergeTickets = mergeTickets + (others:IsNull(1) and 0 or others:GetInt32(1))
                        mergeFlag = math.max(mergeFlag, others:GetUInt8(2))
                    else
                        blockedBy = list
                    end
                end
            until not others:NextRow()
        end

        local ok = blockedBy == nil
        if not ok then
            PrintError("CarbonCopy: tickets move: account "..cc_accountLabel(acc).." also has a balance for realms \""..blockedBy.."\", which overlaps \""
                ..to.."\" but covers other realms too. Not moved: merge or change that row first.")
        end
        if ok and #merge > 0 then
            -- add the merged tickets first and confirm (against a read taken right before), then remove the merged rows;
            -- if they can't be removed the add is undone, so tickets are never lost or doubled
            local pre = CharDBQuery('SELECT `tickets` FROM '..cc_ticketTableSql..where..fromSql..' LIMIT 1;')
            pre = pre and pre:GetInt32(0) or row.tickets
            CharDBQuery('UPDATE '..cc_ticketTableSql..' SET `tickets` = `tickets` + '..mergeTickets..', `starter_tickets_given` = GREATEST(`starter_tickets_given`, '
                ..mergeFlag..')'..where..fromSql..';')
            local check = CharDBQuery('SELECT `tickets` FROM '..cc_ticketTableSql..where..fromSql..' LIMIT 1;')
            ok = mergeTickets == 0 or (check ~= nil and check:GetInt32(0) >= pre + mergeTickets)
            if ok then
                local mergeWhere = ' WHERE `account_id` = '..acc..' AND `realm_ids` IN ('..table.concat(merge, ', ')..')'
                CharDBQuery('DELETE FROM '..cc_ticketTableSql..mergeWhere..';')
                if CharDBQuery('SELECT 1 FROM '..cc_ticketTableSql..mergeWhere..' LIMIT 1;') ~= nil then
                    ok = false
                    CharDBQuery('UPDATE '..cc_ticketTableSql..' SET `tickets` = `tickets` - '..mergeTickets..where..fromSql..';')
                    PrintError("CarbonCopy: tickets move: the merged balances of account "..cc_accountLabel(acc).." could not be removed, see the SQL error above. "
                        .."The added tickets were taken back again. Not moved.")
                end
            else
                PrintError("CarbonCopy: tickets move: the tickets of account "..cc_accountLabel(acc).." could not be merged, see the SQL error above. Not moved.")
            end
        end
        if ok then
            CharDBQuery('UPDATE '..cc_ticketTableSql..' SET `realm_ids` = '..toSql..where..fromSql..';')
            ok = CharDBQuery('SELECT 1 FROM '..cc_ticketTableSql..where..fromSql..' LIMIT 1;') == nil
                and CharDBQuery('SELECT 1 FROM '..cc_ticketTableSql..where..toSql..' LIMIT 1;') ~= nil
            if not ok then
                PrintError("CarbonCopy: tickets move: the realms of account "..cc_accountLabel(acc).."'s balance could not be changed from \""..from.."\" to \""
                    ..to.."\", see the SQL error above."..(#merge > 0 and " The merged balances were already added to it and removed." or ""))
            end
        end
        if ok then
            count = count + 1
            movedTickets = row.tickets + mergeTickets
        else
            failed = failed + 1
        end
    end

    if failed > 0 then
        say("TICKETS_MOVE_PARTIAL", failed, from)
    end
    local adminName, adminGuid = player and player:GetName() or "console", player and tonumber(tostring(player:GetGUID())) or nil
    if accountLabel then
        if count > 0 then
            say("TICKETS_MOVE_DONE_ACCOUNT", accountLabel, from, to, movedTickets)
            if not toSet.all and not toSet[tostring(CC_REALM_ID)] then
                say("TICKETS_MOVE_LEFT_REALM", CC_REALM_ID, to, accountLabel)
            end
            cc_logAdmin(adminName, adminGuid, nil, nil, nil, CC_ACTION_GM_MOVE, movedTickets, movedTickets, CC_STATUS_SUCCESS,
                "Changed the ticket balance of account "..accountLabel.." from realms \""..from.."\" to \""..to.."\"")
        end
        return
    end
    say("TICKETS_MOVE_DONE", count, from, to)
    if CC_TICKET_REALMS == from then
        say("TICKETS_MOVE_STILL_USING", from)
    end
    cc_logAdmin(adminName, adminGuid, nil, nil, nil,
        CC_ACTION_GM_MOVE, nil, nil, CC_STATUS_SUCCESS, "Changed "..count.." ticket balance(s) from realms \""..from.."\" to \""..to.."\"")
end

-- .carboncopy tickets lookup|add|remove $target [$amount] and tickets move   (GM or console; the caller checks the rank)
-- $target: $characterName, --character $characterName or --account $accountName (see cc_readTarget).
local function cc_execTicketsCommand(player, chatHandler, commandArray, command, logName, logGuid, logLabel)
    local say = cc_chatSay(player, chatHandler)
    local action = commandArray[3] and string.lower(commandArray[3])
    if action == "move" then
        cc_execTicketsMove(player, say, command)
        return
    end
    if action ~= "add" and action ~= "remove" and action ~= "lookup" then
        cc_sendTicketsSyntax(say)
        return
    end
    local syntaxKey = (action == "add" and "SYNTAX_TICKETS_ADD") or (action == "remove" and "SYNTAX_TICKETS_REMOVE") or "SYNTAX_TICKETS_LOOKUP"
    local actionCode = (action == "add" and CC_ACTION_GM_ADD) or (action == "remove" and CC_ACTION_GM_REMOVE) or CC_ACTION_GM_LOOKUP
    local cmdName = ".carboncopy tickets "..action

    local kind, name, nextIdx = cc_readTarget(commandArray, 4)
    local amountArg = (kind ~= nil and action ~= "lookup") and commandArray[nextIdx] or nil
    local extraArg = kind ~= nil and commandArray[nextIdx + (action == "lookup" and 0 or 1)] or nil
    if kind == nil or (action ~= "lookup" and amountArg == nil) or extraArg ~= nil then
        say(syntaxKey)
            return
    end
    if amountArg ~= nil and not cc_validTicketAmount(amountArg) then
        say("TICKETS_BAD_AMOUNT", cmdName, amountArg)
        return
    end

    -- target_name holds a character name (12 characters): account targets go into the reason instead
    local logTarget = kind == "character" and name or nil
    local logReason = logLabel.." "..cmdName.." "..(kind == "account" and "--account " or "")..name..(amountArg and (" "..amountArg) or "")
    local accountId, characterGuid = cc_targetAccountId(kind, name)
    if accountId == nil then
        local key = (kind == "account" and "TICKETS_ACCOUNT_NOT_FOUND") or (action == "lookup" and "TICKETS_CHAR_NOT_FOUND") or "TICKETS_PLAYER_NOT_FOUND"
        if action == "lookup" then
            say(key)
            cc_logAdmin(logName, logGuid, logTarget, nil, nil, actionCode, nil, nil, CC_STATUS_FAILED, cc_t(nil, key))
        else
            chatHandler:SendSysMessage(cc_t(player, key).." "..cc_t(player, syntaxKey))
            cc_logAdmin(logName, logGuid, logTarget, nil, nil, actionCode, nil, nil, CC_STATUS_FAILED, cc_t(nil, key).." "..cc_t(nil, syntaxKey))
        end
        return
    end

    local accountText = cc_accountLabel(accountId)
    logReason = logReason.." (account "..accountText..")"
    cc_ensureStarterTickets(accountId, player, "Starter tickets granted before a ticket check")
    local oldTickets = cc_ticketBalance(accountId)

    if action == "lookup" then
        if kind == "account" then
            say("TICKETS_LOOKUP_RESULT_ACCOUNT", accountText, oldTickets)
        else
            say("TICKETS_LOOKUP_RESULT", cc_characterLabel(name, characterGuid), accountText, oldTickets)
        end
        cc_logAdmin(logName, logGuid, logTarget, nil, nil, actionCode, oldTickets, oldTickets, CC_STATUS_SUCCESS, logReason)
        return
    end

    local amount = tonumber(amountArg)
    local failKey
    if action == "add" and (oldTickets < 0 or oldTickets + amount > CC_MAX_TICKETS) then   -- the new total may not pass the cap
        failKey = "TICKETS_TOTAL_TOO_LARGE"
    elseif action == "remove" and (oldTickets <= 0 or oldTickets < amount) then
        failKey = "TICKETS_NOT_ENOUGH_TO_REMOVE"
    end
    if failKey ~= nil then
        local args = failKey == "TICKETS_TOTAL_TOO_LARGE" and { amountArg, accountText, oldTickets, oldTickets + amount, CC_MAX_TICKETS }
            or { amountArg, accountText, oldTickets }
        say(failKey, cc_unpack(args))
        cc_logAdmin(logName, logGuid, logTarget, nil, nil, actionCode, oldTickets, oldTickets, CC_STATUS_FAILED, cc_t(nil, failKey, cc_unpack(args)))
        return
    end

    local delta = action == "add" and amount or -amount
    cc_changeTickets(accountId, delta)
    local doneKey = action == "add" and "TICKETS_ADDED" or "TICKETS_REMOVED"
    if kind == "account" then
        say(doneKey.."_ACCOUNT", cc_actor(player), cmdName, amountArg, accountText, oldTickets, oldTickets + delta)
    else
        say(doneKey, cc_actor(player), cmdName, amountArg, cc_characterLabel(name, characterGuid), accountText, oldTickets, oldTickets + delta)
    end
    cc_logAdmin(logName, logGuid, logTarget, nil, nil, actionCode, oldTickets, oldTickets + delta, CC_STATUS_SUCCESS, logReason)
end

-- restore / revoke $target ...: --character $name is the same as $name; --account $accountName runs the command for
-- every character of that account that has logged mail items (each one is checked, kicked and locked on its own).
local function cc_forEachTarget(say, commandArray, startIdx, run)
    local kind, name, nextIdx = cc_readTarget(commandArray, startIdx)
    if kind == nil then
        run({}, startIdx)   -- shows the syntax
        return
    end
    local function argsFor(characterName)
        local a = {}
        for n = 1, startIdx - 1 do
            a[n] = commandArray[n]
        end
        a[startIdx] = characterName
        for n = nextIdx, #commandArray do
            a[startIdx + 1 + n - nextIdx] = commandArray[n]
        end
        return a
    end
    if kind == "character" then
        run(argsFor(name), startIdx)
        return
    end
    local accountId = cc_targetAccountId(kind, name)
    if accountId == nil then
        say("TICKETS_ACCOUNT_NOT_FOUND")
        return
    end
    local q = CharDBQuery('SELECT DISTINCT c.`name` FROM `'..Config.customDbName..'`.`'..cc_mailItemsTable..'` m '
        ..'JOIN `characters` c ON c.`guid` = m.`target_guid` WHERE c.`account` = '..accountId
        ..' AND m.`superseded_by_id` IS NULL AND m.`revoked_at` IS NULL ORDER BY c.`name`;')
    if q == nil then
        say("RESTORE_ACCOUNT_NONE", cc_accountLabel(accountId))
        return
    end
    local names = {}
    repeat
        table.insert(names, q:GetString(0))
    until not q:NextRow()
    say("RESTORE_ACCOUNT_CHARACTERS", cc_accountLabel(accountId), #names, table.concat(names, ", "))
    for _, characterName in ipairs(names) do
        run(argsFor(characterName), startIdx)
    end
end

function cc_CopyCharacter(event, player, command, chatHandler)
    -- shared by the branches below (they used to be globals, cleared again by cc_resetVariables)
    local oldTickets, accountId, Data_SQL, QueryString

    local commandArray = cc_splitString(command)
    local sourceName = player and player:GetName() or "console"
    local sourceGuid = player and tonumber(tostring(player:GetGUID())) or nil
    if commandArray[2] ~= nil then
        commandArray[2] = commandArray[2]:gsub("[\"';\\, ]", "")
        if commandArray[3] ~= nil then
            commandArray[3] = commandArray[3]:gsub("[\"';\\, ]", "")
        end
        if commandArray[4] ~= nil then
            commandArray[4] = commandArray[4]:gsub("[\"';\\, ]", "")
        end
        if commandArray[5] ~= nil then
            commandArray[5] = commandArray[5]:gsub("[\"';\\, ]", "")
        end
    end

    if commandArray[1] ~= "carboncopy" and commandArray[1] ~= "addcctickets" and commandArray[1] ~= "CCACCOUNTTICKETS" then
        return
    end

    if cc_scriptIsBusy ~= 0 and cc_copyStartedAt ~= nil and os.time() - cc_copyStartedAt > CC_WATCHDOG_SECONDS then
        cc_copyFailed("watchdog", "copy still not finished after "..CC_WATCHDOG_SECONDS.." seconds")
    end
    -- Only one copy can run at a time (it keeps its state in the shared cc_* variables). Everything else - ticket
    -- commands, CCACCOUNTTICKETS from the website, restore, revoke, logs - works during a copy: ticket changes are
    -- added on top of the stored balance in one statement, so they can't clash with the copy's own deduction.
    local cc_subCommands = { help = true, ["--help"] = true, config = true, settings = true, tickets = true, logs = true,
        restore = true, revoke = true, cleanup = true }
    local isCopyRequest = commandArray[1] == "carboncopy" and player ~= nil and commandArray[2] ~= nil
        and not cc_subCommands[string.lower(commandArray[2])]
    if cc_scriptIsBusy ~= 0 and isCopyRequest then
        local reason = cc_t(nil, "ERR_SERVER_BUSY")
        chatHandler:SendSysMessage(cc_t(player, "ERR_SERVER_BUSY"))
        PrintInfo("CarbonCopy user request failed because the script has a scheduled task.")
        if commandArray[1] == "carboncopy" and player ~= nil then
            cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), nil, nil, CC_STATUS_FAILED, reason)
        end
        return false
    end

    if commandArray[1] == "carboncopy" then
        local ccSubCommandConsole = nil
        if commandArray[2] ~= nil then
            ccSubCommandConsole = string.lower(commandArray[2])
        end

        if player == nil and ccSubCommandConsole == "tickets" then
            cc_execTicketsCommand(nil, chatHandler, commandArray, command, "console", nil, "Console")
            return false
        end

        if player == nil and ccSubCommandConsole == "restore" then
            local say = cc_chatSay(nil, chatHandler)
            cc_forEachTarget(say, commandArray, 3, function(args, idx) cc_execRestoreCommand(nil, say, args, idx) end)
            return false
        end

        if player == nil and ccSubCommandConsole == "cleanup" then
            cc_execCleanupCommand(nil, cc_chatSay(nil, chatHandler), commandArray[3])
            return false
        end

        if player == nil and ccSubCommandConsole == "revoke" then
            local say = cc_chatSay(nil, chatHandler)
            cc_forEachTarget(say, commandArray, 3, function(args, idx) cc_execRevokeCommand(nil, say, args, idx) end)
            return false
        end

        if player == nil and ccSubCommandConsole == "logs" then
            cc_execLogsCommand(chatHandler, commandArray, 3)
            return false
        end

        if player == nil and (ccSubCommandConsole == "config" or ccSubCommandConsole == "settings") then
            cc_execConfigCommand(chatHandler)
            return false
        end

        -- console / SOAP: list the commands that work from here
        if player == nil and (ccSubCommandConsole == "help" or ccSubCommandConsole == "--help") then
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_LOOKUP"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_ADD"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_REMOVE"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_MOVE"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_MOVE_ACCOUNT"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_CONFIG"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_LOGS"))
            cc_sendRestoreSyntax(cc_chatSay(player, chatHandler))
                cc_sendRevokeSyntax(cc_chatSay(player, chatHandler))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_ADDCCTICKETS")) -- Kept for Legacy / Compatibility
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_CCACCOUNTTICKETS"))
            chatHandler:SendSysMessage(cc_t(player, "CONSOLE_COPY_INGAME"))
            return false
        end

        if player == nil then
            local reason = cc_t(nil, "ERR_COPY_FROM_CONSOLE")
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_FROM_CONSOLE"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_ADDCCTICKETS")) -- Kept for Legacy / Compatibility
            return false
        end
        -- make sure the player is properly ranked
        if player:GetGMRank() < Config.minGMRankForCopy then
            local reason = cc_t(nil, "ERR_NO_PERMISSION")
            chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
            cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), nil, nil, CC_STATUS_FAILED, reason)
            return false
        end

        -- provide syntax help (GM only, it lists the GM ticket/config/logs commands)
        if string.lower(commandArray[2] or "") == "help" then
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
                return false
            end
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_COPY"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_CONFIG"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_LOOKUP"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_ADD"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_REMOVE"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_MOVE"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_TICKETS_MOVE_ACCOUNT"))
            chatHandler:SendSysMessage(cc_t(player, "SYNTAX_LOGS"))
            if player:GetGMRank() >= cc_minGMRankForRestore then
                cc_sendRestoreSyntax(cc_chatSay(player, chatHandler))
                cc_sendRevokeSyntax(cc_chatSay(player, chatHandler))
            end
            return false
        end

        -- print the available tickets
        local accountId = player:GetAccountId()
        cc_ensureStarterTickets(accountId, player, "Starter tickets granted before a ticket check")
        local _ticketsAtEntrySQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;')
        local ticketsAtEntry = _ticketsAtEntrySQL ~= nil and _ticketsAtEntrySQL:GetInt32(0) or Config.freeTickets
        _ticketsAtEntrySQL = nil
        if commandArray[2] == nil then
            local Data_SQL
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;');
            if Data_SQL  ~= nil then
                oldTickets = Data_SQL:GetInt32(0)
                cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), oldTickets, oldTickets, CC_STATUS_SUCCESS, "Ticket balance lookup")
            else
                oldTickets = Config.freeTickets
                cc_createBalanceRow(accountId)
                cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), 0, Config.freeTickets, CC_STATUS_FREE_CONFIG_TICKET, "Free config ticket granted")
            end
            -- ticket cost list and map warning first, the most important lines last
            -- (closest to the chat input): balance, how to use it, and whether this character can be copied
            cc_sendTicketCosts(player, chatHandler)
            if not cc_has_value(cc_maps, player:GetMapId()) then
                chatHandler:SendSysMessage(cc_info(player, "WRONG_MAP"))
            end

            chatHandler:SendSysMessage(cc_info(player, "TICKETS", oldTickets))
            chatHandler:SendSysMessage(cc_info(player, "USAGE"))
            local level = player:GetLevel()
            local cost = cc_ticketCostForLevel(level)
            if level > Config.maxLevel or cost == nil then
                chatHandler:SendSysMessage(cc_info(player, "LEVEL_TOO_HIGH", level, Config.maxLevel))
            elseif oldTickets < cost then
                chatHandler:SendSysMessage(cc_info(player, "NOT_ENOUGH_TICKETS", level, cost, oldTickets))
            else
                chatHandler:SendSysMessage(cc_info(player, "ELIGIBLE", level, cost))
            end

            return false
        end

        local ccSubCommand = string.lower(commandArray[2])
        if ccSubCommand == "config" or ccSubCommand == "settings" then
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
                return false
            end

            cc_execConfigCommand(chatHandler)
            return false
        end

        if ccSubCommand == "tickets" then
            -- every tickets action (lookup / add / remove / move / syntax) is GM only
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
                return false
            end
            cc_execTicketsCommand(player, chatHandler, commandArray, command, sourceName, sourceGuid, "GM")
            return false
        end

        if ccSubCommand == "logs" then
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
                return false
            end
            cc_execLogsCommand(chatHandler, commandArray, 3)
            return false
        end

        if ccSubCommand == "restore" then
            if player:GetGMRank() < cc_minGMRankForRestore then
                chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
                return false
            end
            local say = cc_chatSay(player, chatHandler)
            cc_forEachTarget(say, commandArray, 3, function(args, idx) cc_execRestoreCommand(player, say, args, idx) end)
            return false
        end

        if ccSubCommand == "cleanup" then
            if player:GetGMRank() < cc_minGMRankForRestore then
                chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
                return false
            end
            cc_execCleanupCommand(player, cc_chatSay(player, chatHandler), commandArray[3])
            return false
        end

        if ccSubCommand == "revoke" then
            if player:GetGMRank() < cc_minGMRankForRestore then
                chatHandler:SendSysMessage(cc_t(player, "ERR_NO_PERMISSION"))
                return false
            end
            local say = cc_chatSay(player, chatHandler)
            cc_forEachTarget(say, commandArray, 3, function(args, idx) cc_execRevokeCommand(player, say, args, idx) end)
            return false
        end

        -- check maxLevel
        if player:GetLevel() > Config.maxLevel then
            local reason = cc_t(nil, "ERR_COPY_LEVEL_TOO_HIGH", Config.maxLevel)
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_LEVEL_TOO_HIGH", Config.maxLevel))
            cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            return false
        end

        cc_playerGUID = tostring(player:GetGUID())
        cc_playerGUID = tonumber(cc_playerGUID)
        local targetName = cc_normalizeCharacterName(commandArray[2])

        --check for target character to be on same account
        local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(targetName).." LIMIT 1;");
        if Data_SQL == nil then
            local reason = cc_t(nil, "ERR_COPY_NAME_NOT_FOUND")
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NAME_NOT_FOUND"))
            cc_logPlayer(sourceName, sourceGuid, targetName, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            return false
        end
        local targetAccountId = Data_SQL:GetUInt32(0)
        Data_SQL = nil
        if targetAccountId ~= accountId then
            local reason = cc_t(nil, "ERR_COPY_NOT_SAME_ACCOUNT")
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NOT_SAME_ACCOUNT"))
            cc_logPlayer(sourceName, sourceGuid, targetName, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            return false
        end

        local Data_SQL = CharDBQuery("SELECT `guid` FROM `characters` WHERE `name` = "..cc_sqlQuote(targetName).." LIMIT 1;");
        local newCharacter
        if Data_SQL ~= nil then
            newCharacter = Data_SQL:GetUInt32(0)
       	else
            local reason = cc_t(nil, "ERR_COPY_NAME_NOT_FOUND")
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NAME_NOT_FOUND"))
            cc_logPlayer(sourceName, sourceGuid, targetName, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            return false
        end
        Data_SQL = nil

        --check for available tickets
        cc_ensureStarterTickets(accountId, player, "Starter tickets granted before a ticket check")
        local Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..';');
        local availableTickets
        local requiredTickets
        if Data_SQL ~= nil then
            availableTickets = Data_SQL:GetInt32(0)
            Data_SQL = nil
        else
            cc_createBalanceRow(accountId)
            availableTickets = Config.freeTickets
        end

        if Config.ticketCost == "single" then
            if availableTickets ~= nil and availableTickets <= 0 then
                local reason = cc_t(nil, "ERR_COPY_NOT_ENOUGH_TICKETS")
                chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NOT_ENOUGH_TICKETS"))
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                return false
            end
            requiredTickets = 1
        elseif Config.ticketCost == "level" then
            -- cost of the first ticket_Cost bracket at or above the level; nil if no bracket covers it
            -- (the old loop here never ended in that case and froze the server)
            requiredTickets = cc_ticketCostForLevel(player:GetLevel())
            if requiredTickets == nil then
                local reason = cc_t(nil, "ERR_COPY_LEVEL_TOO_HIGH", Config.maxLevel)
                chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_LEVEL_TOO_HIGH", Config.maxLevel))
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason.." (no ticket_Cost bracket for this level)")
                PrintError("CarbonCopy: no ticket_Cost bracket covers level "..player:GetLevel()..". Add one in CarbonCopy_Config.lua.")
                return false
            end
            if availableTickets ~= nil and availableTickets <= 0 then
                local reason = cc_t(nil, "ERR_COPY_NOT_ENOUGH_TICKETS")
                chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NOT_ENOUGH_TICKETS"))
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                return false
            end
            if availableTickets < requiredTickets then
                local reason = cc_t(nil, "ERR_COPY_NOT_ENOUGH_TICKETS")
                chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NOT_ENOUGH_TICKETS"))
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                return false
            end
        else
            PrintError("Unhandled exception in CarbonCopy. Config.ticketCost is neither set to \"single\" nor \"level\".")
            chatHandler:SendSysMessage(cc_t(player, "ERR_SERVER_BUSY"))
            return false
        end

        --check for target character to be same class/race
        local Data_SQL = CharDBQuery('SELECT `race`, `class` FROM `characters` WHERE `guid` = '..cc_playerGUID..' LIMIT 1;');
        local sourceRace = Data_SQL:GetUInt8(0)
        local sourceClass = Data_SQL:GetUInt8(1)
        Data_SQL = nil

        local Data_SQL = CharDBQuery('SELECT `race`, `class` FROM `characters` WHERE `guid` = '..newCharacter..' LIMIT 1;');
        local targetRace = Data_SQL:GetUInt8(0)
        local targetClass = Data_SQL:GetUInt8(1)
        Data_SQL = nil

        if sourceRace ~= targetRace then
            local reason = cc_t(nil, "ERR_COPY_NOT_SAME_RACE")
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NOT_SAME_RACE"))
            cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
            return false
        end
        if sourceClass ~= targetClass then
            local reason = cc_t(nil, "ERR_COPY_NOT_SAME_CLASS")
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_NOT_SAME_CLASS"))
            cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
            return false
        end

        -- check if target character wasn't logged in
        local cc_cinematic
        local Data_SQL = CharDBQuery('SELECT cinematic FROM characters WHERE guid = '..newCharacter..';');
        if Data_SQL ~= nil then
            cc_cinematic = Data_SQL:GetUInt16(0)
            if cc_cinematic == 1 then
                local reason = cc_t(nil, "ERR_COPY_ALREADY_LOGGED_IN")
                chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_ALREADY_LOGGED_IN"))
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                cc_cinematic = nil
                return false
            end
        else
            PrintError("Unhandled exception in CarbonCopy. Could not read characters.cinematic from cc_playerGUID "..newCharacter..".")
        end

        -- check if target character is logged in currently in case cinematic wasnt already written to db
        local cc_online
        local Data_SQL = CharDBQuery('SELECT online FROM characters WHERE guid = '..newCharacter..';');
        if Data_SQL ~= nil then
            cc_online = Data_SQL:GetUInt16(0)
            if cc_online == 1 then
                local reason = cc_t(nil, "ERR_COPY_ALREADY_LOGGED_IN")
                chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_ALREADY_LOGGED_IN"))
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                cc_online = nil
                return false
            end
        else
            PrintError("Unhandled exception in CarbonCopy. Could not read characters.online from cc_playerGUID "..newCharacter..".")
        end

        -- check source characters location
        local cc_mapId
        cc_mapId = player:GetMapId()
        if not cc_has_value(cc_maps, cc_mapId) then
            local reason = cc_t(nil, "ERR_COPY_WRONG_MAP")
            chatHandler:SendSysMessage(cc_t(player, "ERR_COPY_WRONG_MAP"))
            cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
            return false
        end

        -------------- COPY SCRIPT STARTS HERE ---------------------
        --set Global variable to prevent simultaneous action and lock the target.
        --The ban is lifted by cc_fixItems as soon as the copy is done; 45s is only the fallback if that never runs.
        cc_lockCharacter(newCharacter, CC_BAN_REASON_COPY, "CarbonCopy")
        cc_scriptIsBusy = 1
        cc_copyToken = cc_copyToken + 1
        cc_copyStartedAt = os.time()   -- set together with the busy lock, so the watchdog can always clear it
        cc_newCharacter = newCharacter
        cc_newCharacterName = targetName
        cc_copyTicketsBefore = availableTickets
        cc_copyTicketsAfter = availableTickets - requiredTickets
        cc_copySourceName = sourceName
        cc_copySourceLevel = player:GetLevel()

        -- save the source character to db to prevent recent changes from being not applied
        player:SaveToDB()

        --fetch all required variables before 1st yield
        -- by class id: GetClassAsString(0) is empty when the server's DBC files aren't enUS
        cc_playerString = ({ [3] = "Hunter", [7] = "Shaman" })[player:GetClass()] or "Other"
        cc_logPlayer(sourceName, sourceGuid, targetName, cc_newCharacter, player:GetLevel(), availableTickets, availableTickets - requiredTickets, CC_STATUS_SUCCESS, "Copy started")
        PrintInfo("1) The player with GUID "..cc_playerGUID.." has succesfully initiated the .carboncopy command. Target character: "..cc_newCharacter);
        chatHandler:SendSysMessage(cc_t(player, "COPY_STARTED", requiredTickets, availableTickets - requiredTickets))
        -- Display English and Italian (as Italian doesn't have a locale in Wrath), plus the player's own locale
        local locale = player:GetDbcLocale()
        chatHandler:SendSysMessage(cc_tl(0, "COPY_STAY"))
        chatHandler:SendSysMessage(cc_tl(0, "COPY_STAY_ITALIAN"))
        if locale ~= 0 and L.COPY_STAY[locale] ~= nil then
            chatHandler:SendSysMessage(cc_tl(locale, "COPY_STAY"))
        end
        -- mails for the new character use the copying player's locale (same account, same client)
        cc_copyLocale = locale

        -- what a failed copy needs to refund and unlock (see cc_copyFailed)
        cc_copyAccountId = accountId
        cc_copyCharged = 0
        cc_copyMailed = false
        cc_copyStartedAt = os.time()

        -- resumes the copy once a second until it is finished (cc_resumeSubRoutine removes the event)
        cc_eventId = CreateLuaEvent(cc_resumeSubRoutine, 1000, 0)

        cc_subRoutine = coroutine.create(function ()

        -- deduct tickets
        if Config.ticketCost == "single" then
            requiredTickets = 1
        end
        -- only if the balance still covers it (another worldserver sharing the balance, or a GM, may have used it since
        -- the check). One statement takes the tickets and marks this copy's charge row as applied, or does neither,
        -- so the flag read back afterwards is exact.
        local chargeToken = cc_sqlQuote(CC_REALM_ID.."-"..accountId.."-"..cc_copyToken.."-"..os.time())
        CharDBQuery('INSERT INTO '..cc_chargesTableSql..' (`token`, `account_id`, `amount`) VALUES ('..chargeToken..', '
            ..accountId..', '..requiredTickets..');')
        CharDBQuery('UPDATE '..cc_ticketTableSql..' AS b JOIN '..cc_chargesTableSql..' AS c ON c.`token` = '..chargeToken
            ..' AND c.`applied` = 0 SET b.`tickets` = b.`tickets` - '..requiredTickets..', c.`applied` = 1 '
            ..'WHERE b.`account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' AND b.`tickets` >= '..requiredTickets..';')
        local charge = CharDBQuery('SELECT `applied` FROM '..cc_chargesTableSql..' WHERE `token` = '..chargeToken..' LIMIT 1;')
        local charged = charge ~= nil and charge:GetUInt8(0) == 1
        CharDBQuery('DELETE FROM '..cc_chargesTableSql..' WHERE `token` = '..chargeToken..';')
        if charge == nil then
            error("the ticket deduction could not be recorded, see the SQL error above")
        elseif not charged then
            error("not enough tickets any more (the balance changed since the check)")
        end
        cc_copyCharged = requiredTickets


        -- Copy characters table
        local QueryString
        QueryString = 'UPDATE `characters` AS t1 '
        QueryString = QueryString..'INNER JOIN `characters` AS t2 ON t2.guid = '..cc_playerGUID..' '
        QueryString = QueryString..'SET t1.level = t2.level, t1.xp = t2.xp, t1.taximask = t2.taximask, '
        QueryString = QueryString..'t1.leveltime = t2.leveltime, t1.stable_slots = t2.stable_slots, t1.health = t2.health, '
        QueryString = QueryString..'t1.power1 = t2.power1, t1.power2 = t2.power2, t1.power3 = t2.power3, t1.power4 = t2.power4, '
        QueryString = QueryString..'t1.power5 = t2.power5, t1.power6 = t2.power6, t1.power7 = t2.power7, t1.talentGroupsCount = t2.talentGroupsCount, '
        QueryString = QueryString..'t1.activeTalentGroup = t2.activeTalentGroup, '
        QueryString = QueryString..'t1.exploredZones = t2.exploredZones WHERE t1.guid = '..cc_newCharacter..';'
        local Data_SQL = CharDBQuery(QueryString);
        QueryString = nil
        Data_SQL = nil
        local Data_SQL = CharDBQuery('UPDATE characters SET cinematic = 1 WHERE guid = '..cc_newCharacter..';');

        -- start the new character in its faction's capital (Config.teleportToCapital)
        if cc_teleportToCapital then
            local pos = cc_capitalForRace(sourceRace)
            if pos ~= nil then
                CharDBQuery('UPDATE `characters` SET `map` = '..tonumber(pos.map)..', `zone` = '..tonumber(pos.zone)
                    ..', `position_x` = '..tonumber(pos.x)..', `position_y` = '..tonumber(pos.y)..', `position_z` = '..tonumber(pos.z)
                    ..', `orientation` = '..tonumber(pos.o or 0)..', `instance_id` = 0, `instance_mode_mask` = 0'
                    ..', `trans_x` = 0, `trans_y` = 0, `trans_z` = 0, `trans_o` = 0, `transguid` = 0'
                    ..' WHERE `guid` = '..cc_newCharacter..';')
            end
        end

        coroutine.yield()
        -- Copy achivements level ups 10, 20, 30, 40, 50, 60, 70 or 80 if they exist and use carboncopy sucess timestamp when it was "obtained".
        local level_achievements = {6, 7, 8, 9, 10, 11, 12, 13}
        local achievement_list = table.concat(level_achievements, ",")
        local Data_SQL = CharDBQuery('DELETE FROM character_achievement WHERE guid = '..cc_newCharacter..' AND achievement IN ('..achievement_list..');')
        local Data_SQL = CharDBQuery('INSERT INTO character_achievement (guid, achievement, date) SELECT '..cc_newCharacter..', achievement, UNIX_TIMESTAMP() FROM character_achievement WHERE guid = '..cc_playerGUID..' AND achievement IN ('..achievement_list..');')
        Data_SQL = nil

        coroutine.yield()
        -- Hearthstone bind point: the capital (Config.homebindToCapital) or the source's; if that isn't valid, the capital
        local bind
        if cc_homebindToCapital then
            bind = cc_capitalForRace(sourceRace)
        else
            local hb = CharDBQuery('SELECT mapId, zoneId, posX, posY, posZ FROM character_homebind WHERE guid = '..cc_playerGUID..' LIMIT 1;')
            if hb ~= nil then
                bind = { map = hb:GetUInt16(0), zone = hb:GetUInt16(1), x = hb:GetFloat(2), y = hb:GetFloat(3), z = hb:GetFloat(4) }
            end
        end
        -- a valid bind point: on a continent, has a zone, not all zero
        local function bindValid(b)
            return b ~= nil and cc_has_value(CC_CONTINENTS, tonumber(b.map)) and (tonumber(b.zone) or 0) ~= 0
                and not (tonumber(b.x) == 0 and tonumber(b.y) == 0 and tonumber(b.z) == 0)
        end
        if not bindValid(bind) then
            -- invalid: the faction's capital (races in neither list already get the neutral position there),
            -- and the neutral position if even that isn't valid
            bind = cc_capitalForRace(sourceRace)
            if not bindValid(bind) then
                bind = cc_capitalPositions.neutral
            end
            PrintInfo("CarbonCopy: the bind point for character "..cc_newCharacter.." wasn't valid, using map "..tostring(bind.map)
                ..", zone "..tostring(bind.zone)..".")
        end
        CharDBQuery('DELETE FROM character_homebind WHERE guid = '..cc_newCharacter..';')
        CharDBQuery('INSERT INTO character_homebind (guid, mapId, zoneId, posX, posY, posZ) VALUES ('..cc_newCharacter..', '
            ..tonumber(bind.map)..', '..tonumber(bind.zone)..', '..tonumber(bind.x)..', '..tonumber(bind.y)..', '..tonumber(bind.z)..');')

        -- Copy character_pet (Shaman totems are mailed with the gear, at the end)
        if cc_playerString == "Hunter" then
            -- the active pet first (slot 0), then a dismissed one (100), then the stabled ones; oldest first within each
            local Data_SQL = CharDBQuery('SELECT id FROM character_pet WHERE owner = '..cc_playerGUID
                ..' ORDER BY CASE WHEN slot = 0 THEN 0 WHEN slot = 100 THEN 1 ELSE 2 END, id LIMIT 1;');
            if Data_SQL ~= nil then
                cc_playerPetId = Data_SQL:GetUInt32(0)
                Data_SQL = nil

                local cc_targetPetId = cc_newPetId()

                CharDBQuery('DELETE FROM character_pet WHERE owner = '..cc_newCharacter..';')
                cc_copyRows('character_pet', 'id = '..cc_playerPetId, { id = cc_targetPetId, owner = cc_newCharacter, slot = 0 }, 'id = '..cc_targetPetId)
                CharDBQuery('DELETE FROM pet_spell WHERE guid = '..cc_targetPetId..';')
                cc_copyRows('pet_spell', 'guid = '..cc_playerPetId, { guid = cc_targetPetId }, 'guid = '..cc_targetPetId)
            end
        end

        coroutine.yield()
        --Copy quests
        local Data_SQL = CharDBQuery('DELETE FROM character_queststatus_rewarded WHERE guid = '..cc_newCharacter..';')
        cc_copyRows('character_queststatus_rewarded', 'guid = '..cc_playerGUID, { guid = cc_newCharacter }, 'guid = '..cc_newCharacter)
        Data_SQL = nil

        coroutine.yield()
        --Copy reputation
        local Data_SQL = CharDBQuery('DELETE FROM character_reputation WHERE guid = '..cc_newCharacter..';')
        cc_copyRows('character_reputation', 'guid = '..cc_playerGUID, { guid = cc_newCharacter }, 'guid = '..cc_newCharacter)
        Data_SQL = nil

        coroutine.yield()
        --Copy skills
        local Data_SQL = CharDBQuery('DELETE FROM character_skills WHERE guid = '..cc_newCharacter..';')
        cc_copyRows('character_skills', 'guid = '..cc_playerGUID, { guid = cc_newCharacter }, 'guid = '..cc_newCharacter)
        Data_SQL = nil

        coroutine.yield()
        --Copy spells
        local Data_SQL = CharDBQuery('DELETE FROM character_spell WHERE guid = '..cc_newCharacter..';')
        cc_copyRows('character_spell', 'guid = '..cc_playerGUID, { guid = cc_newCharacter }, 'guid = '..cc_newCharacter)
        Data_SQL = nil

        coroutine.yield()
        --Copy talents
        local Data_SQL = CharDBQuery('DELETE FROM character_talent WHERE guid = '..cc_newCharacter..';')
        cc_copyRows('character_talent', 'guid = '..cc_playerGUID, { guid = cc_newCharacter }, 'guid = '..cc_newCharacter)
        Data_SQL = nil

        -- Config.resetTalentsAfterCopy: the core resets the active spec at first login (AT_LOGIN_RESET_TALENTS, it
        -- also removes the talent spells properly). The other spec is cleared here: its talents and the spells only
        -- it had are dropped, and talents/spells shared by both specs are left to the active spec only.
        if cc_resetTalentsAfterCopy then
            local sg = CharDBQuery('SELECT activeTalentGroup FROM characters WHERE guid = '..cc_newCharacter..' LIMIT 1;')
            local activeMask = 1
            if sg ~= nil then
                activeMask = (sg:GetUInt8(0) == 1) and 2 or 1   -- spec 1 = mask 1, spec 2 = mask 2
            end
            CharDBQuery('DELETE FROM character_talent WHERE guid = '..cc_newCharacter..' AND (specMask & '..activeMask..') = 0;')
            CharDBQuery('UPDATE character_talent SET specMask = (specMask & '..activeMask..') WHERE guid = '..cc_newCharacter..';')
            CharDBQuery('DELETE FROM character_spell WHERE guid = '..cc_newCharacter..' AND specMask <> 255 AND (specMask & '..activeMask..') = 0;')
            CharDBQuery('UPDATE character_spell SET specMask = (specMask & '..activeMask..') WHERE guid = '..cc_newCharacter
                ..' AND specMask <> 255 AND specMask <> '..activeMask..';')
            CharDBQuery('UPDATE characters SET at_login = (at_login | 4) WHERE guid = '..cc_newCharacter..';')
        end

        coroutine.yield()
        --Copy glyphs
        local Data_SQL = CharDBQuery('DELETE FROM character_glyphs WHERE guid = '..cc_newCharacter..';')
        cc_copyRows('character_glyphs', 'guid = '..cc_playerGUID, { guid = cc_newCharacter }, 'guid = '..cc_newCharacter)
        Data_SQL = nil

        coroutine.yield()
        --Copy actions
        local Data_SQL = CharDBQuery('DELETE FROM character_action WHERE guid = '..cc_newCharacter..';')
        cc_copyRows('character_action', 'guid = '..cc_playerGUID, { guid = cc_newCharacter }, 'guid = '..cc_newCharacter)
        Data_SQL = nil

        coroutine.yield()
        --Copy items
        if not Config.keepStartingItems then
            -- delete everything the new character has except one Hearthstone (if it has one at all)
            local hearthstone = CharDBQuery('SELECT guid FROM item_instance WHERE owner_guid = '..cc_newCharacter..' AND itemEntry = 6948 LIMIT 1;')
            if hearthstone ~= nil then
                local homeStone = hearthstone:GetUInt32(0)
                CharDBQuery('DELETE FROM item_instance WHERE owner_guid = '..cc_newCharacter..' AND guid != '..homeStone..';')
                CharDBQuery('DELETE FROM character_inventory WHERE guid = '..cc_newCharacter..' AND item != '..homeStone..';')
            else
                CharDBQuery('DELETE FROM item_instance WHERE owner_guid = '..cc_newCharacter..';')
                CharDBQuery('DELETE FROM character_inventory WHERE guid = '..cc_newCharacter..';')
            end
        end
        Data_SQL = nil

        -- equipped items (slots 0-18), only the slots that hold something
        local Data_SQL = CharDBQuery('SELECT ci.item, ii.itemEntry FROM character_inventory AS ci '
            ..'INNER JOIN item_instance AS ii ON ii.guid = ci.item '
            ..'WHERE ci.guid = '..cc_playerGUID..' AND ci.bag = 0 AND ci.slot <= 18 ORDER BY ci.slot;')
        local gearEntries = {}
        if Data_SQL ~= nil then
            repeat
                local oldGuid, entry = Data_SQL:GetUInt32(0), Data_SQL:GetUInt32(1)
                if cc_itemExists(entry) then
                    table.insert(cc_oldItemGuids, oldGuid)
                    table.insert(gearEntries, entry)
                else
                    PrintError("CarbonCopy: item entry "..entry.." (item guid "..oldGuid..") no longer exists, not copied.")
                end
            until not Data_SQL:NextRow()
        end
        Data_SQL = nil

        -- optional legacy filler (Config.emptySlotFiller) so every mail is full, like the old script did
        local mailEntries = {}
        for n, entry in ipairs(gearEntries) do
            mailEntries[n] = entry
        end
        -- a new character without a Hearthstone gets one with the gear (not logged, it isn't a copied item)
        if CharDBQuery('SELECT 1 FROM item_instance WHERE owner_guid = '..cc_newCharacter..' AND itemEntry = 6948 LIMIT 1;') == nil then
            table.insert(mailEntries, 6948)
        end
        if cc_emptySlotFiller > 0 and #mailEntries > 0 then
            local fillTo = #mailEntries <= 12 and 12 or 18
            while #mailEntries < fillTo do
                table.insert(mailEntries, cc_emptySlotFiller)
            end
        end
        -- Shaman: only the totems the source character owns, in their own mail. Sent together with the gear at the end,
        -- so a failure in an earlier step still refunds the tickets (nothing is mailed before that).
        if cc_playerString == "Shaman" then
            -- only the totems the source character owns, in their own mail
            -- (earth, fire, water, air, Totem of the Earthen Ring)
            local totems = {}
            for _, entry in ipairs({5175, 5176, 5177, 5178, 46978}) do
                if CharDBQuery('SELECT 1 FROM item_instance WHERE owner_guid = '..cc_playerGUID..' AND itemEntry = '..entry..' LIMIT 1;') ~= nil then
                    table.insert(totems, entry)
                end
            end
            local realTotems = #totems
            if cc_emptySlotFiller > 0 and realTotems > 0 then
                while #totems < 5 do
                    table.insert(totems, cc_emptySlotFiller)
                end
            end
            cc_totemMailGuids = {}
            cc_totemItemGuids = {}
            if #totems > 0 then
                local guids, sent, failed = cc_sendItemMails(cc_newCharacter, cc_tl(cc_copyLocale, "MAIL_TOTEMS_SUBJECT"),
                    (cc_legacyMailText and ("Hello "..targetName..cc_legacyMailText) or cc_tl(cc_copyLocale, "MAIL_TOTEMS_BODY", targetName, cc_mailSignature)), totems)
                if sent > 0 then
                    cc_copyMailed = true
                end
                if failed > 0 then
                    error("the totem mail could not be sent")
                end
                for n = 1, #totems do
                    if guids[n] ~= nil then
                        table.insert(cc_totemMailGuids, guids[n])
                        if n <= realTotems then
                            table.insert(cc_totemItemGuids, guids[n])
                        end
                    end
                end
            end
        end

        if #mailEntries > 0 then
            local guids, sent, failed = cc_sendItemMails(cc_newCharacter, cc_tl(cc_copyLocale, "MAIL_GEAR_SUBJECT"),
                (cc_legacyMailText and ("Hello "..targetName..cc_legacyMailText) or cc_tl(cc_copyLocale, "MAIL_GEAR_BODY", targetName, cc_mailSignature)), mailEntries)
            if sent > 0 then
                cc_copyMailed = true
            end
            if failed > 0 then
                error(failed.." of the gear mails could not be sent")
            end
            for n = 1, #mailEntries do
                cc_newItemGuids[n] = guids[n]
            end
        end
        local token = cc_copyToken
        CreateLuaEvent(function() cc_fixItems(token) end, CC_POLL_MS, 1) -- as soon as the mails are saved (cc_fixItems polls)

        -- the "copy complete" message and the success log are written by cc_fixItems, once the items are really done

        return false
        end)

        return false

    elseif commandArray[1] == "addcctickets" then
        -- make sure the player is properly ranked
        local accountId
        local oldTickets
        local Data_SQL
        if player ~= nil then
            if player:GetGMRank() < Config.minGMRankForTickets then
                return false
            end
            if commandArray[2] == "help" then
                chatHandler:SendSysMessage(cc_t(player, "SYNTAX_ADDCCTICKETS")) -- Kept for Legacy / Compatibility
                return false
            end
            if commandArray[2] == nil or commandArray[3] == nil then
                chatHandler:SendSysMessage(cc_t(player, "SYNTAX_ADDCCTICKETS")) -- Kept for Legacy / Compatibility
                return false
            end

            if not cc_validTicketAmount(commandArray[3]) then
                chatHandler:SendSysMessage(cc_t(player, "TICKETS_BAD_AMOUNT", ".addcctickets", commandArray[3]))
                return false
            end

            local normalisedCharacterName = cc_normalizeCharacterName(commandArray[2])
            local characterGuid
            Data_SQL = CharDBQuery("SELECT `account`, `guid` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;");
            if Data_SQL ~= nil then
                accountId = Data_SQL:GetUInt32(0)
                characterGuid = Data_SQL:GetUInt32(1)
            else
                chatHandler:SendSysMessage(cc_t(player, "TICKETS_PLAYER_NOT_FOUND").." "..cc_t(player, "SYNTAX_ADDCCTICKETS"))
                return false
            end
            Data_SQL = nil
            local Data_SQL
            cc_ensureStarterTickets(accountId, player, "Starter tickets granted before a ticket check")
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;');
            if Data_SQL  ~= nil then
                oldTickets = Data_SQL:GetInt32(0)
            else
                oldTickets = Config.freeTickets   -- never used .carboncopy yet: the starter tickets
            end
            Data_SQL = nil

            if oldTickets < 0 or oldTickets + tonumber(commandArray[3]) > CC_MAX_TICKETS then   -- the new total may not pass the cap
                chatHandler:SendSysMessage(cc_t(player, "TICKETS_TOTAL_TOO_LARGE", commandArray[3], cc_accountLabel(accountId), oldTickets,
                oldTickets + tonumber(commandArray[3]), CC_MAX_TICKETS))
                return false
            end

            -- the `allow_copy_from_id` column is hardcoded to 0 for now. Only copies to the same account are possible.
            local Data_SQL
            cc_changeTickets(accountId, tonumber(commandArray[3]))
            Data_SQL = nil
            chatHandler:SendSysMessage(cc_t(player, "TICKETS_ADDED", cc_actor(player), ".addcctickets", commandArray[3],
                cc_characterLabel(normalisedCharacterName, characterGuid), cc_accountLabel(accountId), oldTickets, oldTickets + tonumber(commandArray[3])))
            cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + tonumber(commandArray[3]), CC_STATUS_SUCCESS, "GM .addcctickets")
            return false
        else
            --player is nil, must be the console. no need to check gm rank and print to console only. not chat
            if commandArray[2] == "help" then
                chatHandler:SendSysMessage(cc_t(player, "SYNTAX_ADDCCTICKETS")) -- Kept for Legacy / Compatibility
                return false
            end
            if commandArray[2] == nil or commandArray[3] == nil then
                chatHandler:SendSysMessage(cc_t(player, "SYNTAX_ADDCCTICKETS")) -- Kept for Legacy / Compatibility
                return false
            end

            if not cc_validTicketAmount(commandArray[3]) then
                chatHandler:SendSysMessage(cc_t(player, "TICKETS_BAD_AMOUNT", ".addcctickets", commandArray[3]))
                return false
            end

            local normalisedCharacterName = cc_normalizeCharacterName(commandArray[2])
            local characterGuid
            Data_SQL = CharDBQuery("SELECT `account`, `guid` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;");
            if Data_SQL ~= nil then
                accountId = Data_SQL:GetUInt32(0)
                characterGuid = Data_SQL:GetUInt32(1)
            else
                chatHandler:SendSysMessage(cc_t(player, "TICKETS_PLAYER_NOT_FOUND").." "..cc_t(player, "SYNTAX_ADDCCTICKETS"))
                return false
            end
            Data_SQL = nil
            local Data_SQL
            cc_ensureStarterTickets(accountId, player, "Starter tickets granted before a ticket check")
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;');
            if Data_SQL  ~= nil then
                oldTickets = Data_SQL:GetInt32(0)
            else
                oldTickets = Config.freeTickets   -- never used .carboncopy yet: the starter tickets
            end
            Data_SQL = nil

            if oldTickets < 0 or oldTickets + tonumber(commandArray[3]) > CC_MAX_TICKETS then   -- the new total may not pass the cap
                chatHandler:SendSysMessage(cc_t(player, "TICKETS_TOTAL_TOO_LARGE", commandArray[3], cc_accountLabel(accountId), oldTickets,
                oldTickets + tonumber(commandArray[3]), CC_MAX_TICKETS))
                return false
            end

            -- the `allow_copy_from_id` column is hardcoded to 0 for now. Only copies to the same account are possible.
            local Data_SQL
            cc_changeTickets(accountId, tonumber(commandArray[3]))
            Data_SQL = nil
            chatHandler:SendSysMessage(cc_t(player, "TICKETS_ADDED", cc_actor(player), ".addcctickets", commandArray[3],
                cc_characterLabel(normalisedCharacterName, characterGuid), cc_accountLabel(accountId), oldTickets, oldTickets + tonumber(commandArray[3])))
            cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + tonumber(commandArray[3]), CC_STATUS_SUCCESS, "Console .addcctickets")
            return false
        end
    -- command for SOAP interface to send to worldserver console, granting tickets. Syntax: CCACCOUNTTICKETS $accountName $amount
    elseif commandArray[1] == "CCACCOUNTTICKETS" and commandArray[2] ~= nil and commandArray[3] ~= nil and player == nil then
        local Data_SQL
        Data_SQL = AuthDBQuery("SELECT `id` FROM `account` WHERE `username` = "..cc_sqlQuote(commandArray[2])..";")
        if Data_SQL == nil then
            PrintError("CCACCOUNTTICKETS to "..commandArray[2].." has failed.")
            -- reply, so the caller (acore-cms) can tell the tickets were not added
            chatHandler:SendSysMessage(cc_t(nil, "TICKETS_ACCOUNT_NOT_FOUND"))
            cc_logAdmin("console", nil, commandArray[2], nil, nil, CC_ACTION_GM_ADD, nil, nil, CC_STATUS_FAILED, "CCACCOUNTTICKETS account not found")
            return false
        else
            accountId = Data_SQL:GetUInt32(0)
        end

        -- whole number 0-1000 only; anything else used to throw a Lua error and give SOAP no reply
        local amount = tonumber(commandArray[3])
        if not cc_validTicketAmount(commandArray[3]) then
            chatHandler:SendSysMessage(cc_t(player, "TICKETS_BAD_AMOUNT", ".CCACCOUNTTICKETS", commandArray[3]))
            return false
        end

        cc_ensureStarterTickets(accountId, player, "Starter tickets granted before a ticket check")
        Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' AND '..CC_MY_BALANCE_SQL..' LIMIT 1;');
        if Data_SQL  ~= nil then
            oldTickets = Data_SQL:GetInt32(0)
        else
            oldTickets = Config.freeTickets   -- never used .carboncopy yet: the starter tickets
        end

        if oldTickets < 0 or oldTickets + tonumber(commandArray[3]) > CC_MAX_TICKETS then   -- the new total may not pass the cap
            chatHandler:SendSysMessage(cc_t(player, "TICKETS_TOTAL_TOO_LARGE", commandArray[3], cc_accountLabel(accountId), oldTickets,
                oldTickets + tonumber(commandArray[3]), CC_MAX_TICKETS))
            cc_logAdmin("console", nil, commandArray[2], nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets, CC_STATUS_FAILED, "CCACCOUNTTICKETS total exceeds max")
            return false
        end

        cc_changeTickets(accountId, amount)
        cc_logAdmin("console", nil, commandArray[2], nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + amount, CC_STATUS_SUCCESS, "CCACCOUNTTICKETS success")
        return false
    elseif player ~= nil then
        -- CCACCOUNTTICKETS is SOAP / console only: stay silent for players, like .addcctickets
        return false
    else
        chatHandler:SendSysMessage(cc_t(player, "SYNTAX_CCACCOUNTTICKETS"))
        return false
    end
end

-- A copy step failed with a Lua/DB error. Refunds the tickets when nothing has been mailed yet (and lets the player
-- try again, the copy overwrites everything it touches), unlocks the new character, releases the lock, tells the player.
function cc_copyFailed(stage, err)
    -- refund / unlock / log / tell the player; protected so the lock below is released even if this part fails
    local cleanupOk, cleanupErr = pcall(function()
        PrintError("CarbonCopy: copy to character "..tostring(cc_newCharacter).." failed during "..stage..": "..tostring(err))
        local refunded = 0
        if cc_copyAccountId ~= nil and (cc_copyCharged or 0) > 0 and not cc_copyMailed then
            CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` SET tickets = tickets + '..cc_copyCharged
                ..' WHERE `account_id` = '..cc_copyAccountId..' AND '..CC_MY_BALANCE_SQL..';')
            refunded = cc_copyCharged
            if cc_newCharacter ~= nil and cc_newCharacter ~= 0 then
                -- the new character may already have the copied level, spells, reputation...: it stays locked (10 years,
                -- same lock reason as a copy) until a copy to it succeeds, which overwrites everything and lifts it.
                -- cinematic 0 so that retry is allowed.
                CharDBQuery('UPDATE `characters` SET `cinematic` = 0 WHERE `guid` = '..cc_newCharacter..';')
                -- the lock may already have expired (watchdog after a stall): put it back first, then extend it
                if CharDBQuery('SELECT 1 FROM `character_banned` WHERE `guid` = '..cc_newCharacter..' AND `active` = 1 AND `banreason` = '
                    ..cc_sqlQuote(CC_BAN_REASON_COPY)..' AND `unbandate` > UNIX_TIMESTAMP() LIMIT 1;') == nil then
                    cc_lockCharacter(cc_newCharacter, CC_BAN_REASON_COPY, "CarbonCopy")
                end
                CharDBQuery('UPDATE `character_banned` SET `unbandate` = UNIX_TIMESTAMP() + 315360000 WHERE `guid` = '..cc_newCharacter
                    ..' AND `active` = 1 AND `banreason` = '..cc_sqlQuote(CC_BAN_REASON_COPY)..';')
            end
        end
        if refunded == 0 and cc_newCharacter ~= nil and cc_newCharacter ~= 0 then
            cc_liftCarbonCopyBan(cc_newCharacter, CC_BAN_REASON_COPY)
        end

        cc_logPlayer(cc_copySourceName or cc_characterNameByGuid(cc_playerGUID), cc_playerGUID, cc_newCharacterName,
            (cc_newCharacter ~= 0) and cc_newCharacter or nil, cc_copySourceLevel,
            cc_copyTicketsBefore, refunded > 0 and cc_copyTicketsBefore or cc_copyTicketsAfter, CC_STATUS_FAILED,
            "Copy failed during "..stage..((refunded > 0 and ", "..refunded.." ticket(s) refunded")
                or (((cc_copyCharged or 0) == 0 and not cc_copyMailed) and ", nothing charged") or ", items already mailed, no refund")
            ..": "..string.sub(tostring(err), 1, 150))

        local copyingPlayer = cc_playerGUID ~= nil and GetPlayerByGUID(cc_playerGUID) or nil
        if copyingPlayer ~= nil then
            if refunded > 0 then
                copyingPlayer:SendBroadcastMessage(cc_t(copyingPlayer, "COPY_FAILED_REFUNDED", refunded))
            elseif (cc_copyCharged or 0) == 0 and not cc_copyMailed then
                copyingPlayer:SendBroadcastMessage(cc_t(copyingPlayer, "COPY_FAILED_NOT_CHARGED"))
            else
                copyingPlayer:SendBroadcastMessage(cc_t(copyingPlayer, "COPY_FAILED_CONTACT_GM"))
            end
        end

    end)
    if not cleanupOk then
        PrintError("CarbonCopy: cleanup after the failed copy also failed: "..tostring(cleanupErr))
    end

    cc_subRoutine = nil
    cc_newCharacter = 0
    cc_newCharacterName = nil
    cc_copyTicketsBefore = nil
    cc_copyTicketsAfter = nil
    cc_copySourceName = nil
    cc_copySourceLevel = nil
    cc_copyAccountId = nil
    cc_copyCharged = 0
    cc_copyMailed = false
    cc_copyStartedAt = nil
    cc_oldItemGuids = {}
    cc_newItemGuids = {}
    cc_totemMailGuids = {}
    cc_totemItemGuids = {}
    cc_fixItemsAttempts = 0
    cc_copyToken = cc_copyToken + 1
    cc_scriptIsBusy = 0
    cc_playerGUID = nil
end

-- Finishes the copy (enchants, mail expiry, logs, unlock); any error goes to cc_copyFailed instead of leaving the lock on.
-- token: cc_copyToken of the copy that scheduled it; a copy that has since ended (watchdog) or been replaced is left alone.
function cc_fixItems(token)
    if token ~= cc_copyToken or cc_scriptIsBusy == 0 then
        return
    end
    local ok, err = pcall(cc_fixItemsStep, token)
    if not ok then
        cc_copyFailed("item fix", err)
    end
end

function cc_fixItemsStep(token)
    local QueryString
    local n
    local Data_SQL

    -- SendMail commits asynchronously; wait (up to pollIntervalMs x pollMaxAttempts) until the mailed items are in the DB
    local mailedGuids = {}
    for _, guid in pairs(cc_newItemGuids) do
        table.insert(mailedGuids, guid)
    end
    for _, guid in ipairs(cc_totemMailGuids) do
        table.insert(mailedGuids, guid)
    end
    if not cc_mailItemsCommitted(mailedGuids) then
        if cc_fixItemsAttempts < CC_POLL_MAX then
            cc_fixItemsAttempts = cc_fixItemsAttempts + 1
            CreateLuaEvent(function() cc_fixItems(token) end, CC_POLL_MS, 1)
            return
        end
        -- never saved: stop here (cc_copyFailed via cc_fixItems) instead of reporting a copy without enchants as done
        error("the copy mails were not saved within "..(CC_POLL_MS * CC_POLL_MAX / 1000).." seconds")
    end
    cc_fixItemsAttempts = 0

    for n,_ in ipairs(cc_oldItemGuids) do
      if cc_newItemGuids[n] ~= nil then
        QueryString = 'UPDATE `item_instance` AS t1 '
        QueryString = QueryString..'INNER JOIN `item_instance` AS t2 ON t2.guid = '..cc_oldItemGuids[n]..' '
        QueryString = QueryString..'SET t1.owner_guid = '..cc_newCharacter..', t1.creatorGuid = t2.creatorGuid, '
        QueryString = QueryString..'t1.duration = t2.duration, t1.charges = t2.charges, t1.flags = '..cc_copyFlagsSql('t2.flags')..', '
        QueryString = QueryString..'t1.enchantments = t2.enchantments, t1.randomPropertyId = t2.randomPropertyId '
        QueryString = QueryString..'WHERE t1.guid = '..cc_newItemGuids[n]..';'
        Data_SQL = CharDBQuery(QueryString);
      end
    end

    -- Copy equipment sets with remapped item GUIDs
    if Config.copyEquipmentSets then
        local guidMap = {}
        for n,_ in ipairs(cc_oldItemGuids) do
            if cc_oldItemGuids[n] ~= nil and cc_newItemGuids[n] ~= nil then
                guidMap[cc_oldItemGuids[n]] = cc_newItemGuids[n]
            end
        end

        CharDBQuery('DELETE FROM `character_equipmentsets` WHERE `guid` = '..cc_newCharacter..';')

        local sets_SQL = CharDBQuery('SELECT `setindex`, `name`, `iconname`, `ignore_mask`, `item0`, `item1`, `item2`, `item3`, `item4`, `item5`, `item6`, `item7`, `item8`, `item9`, `item10`, `item11`, `item12`, `item13`, `item14`, `item15`, `item16`, `item17`, `item18` FROM `character_equipmentsets` WHERE `guid` = '..cc_playerGUID..';')
        if sets_SQL ~= nil then
            repeat
                local setindex    = sets_SQL:GetUInt8(0)
                local name        = sets_SQL:GetString(1)
                local iconname    = sets_SQL:GetString(2)
                local ignore_mask = sets_SQL:GetUInt32(3)
                local items = {}
                for i = 0, 18 do
                    local oldGuid = sets_SQL:GetUInt32(4 + i)
                    items[i] = guidMap[oldGuid] or 0
                end
                CharDBQuery('INSERT INTO `character_equipmentsets` (`guid`, `setindex`, `name`, `iconname`, `ignore_mask`, `item0`, `item1`, `item2`, `item3`, `item4`, `item5`, `item6`, `item7`, `item8`, `item9`, `item10`, `item11`, `item12`, `item13`, `item14`, `item15`, `item16`, `item17`, `item18`) VALUES ('
                    ..cc_newCharacter..', '..setindex..', '..cc_sqlQuote(name)..', '..cc_sqlQuote(iconname)..', '..ignore_mask..', '
                    ..items[0]..', '..items[1]..', '..items[2]..', '..items[3]..', '..items[4]..', '
                    ..items[5]..', '..items[6]..', '..items[7]..', '..items[8]..', '..items[9]..', '
                    ..items[10]..', '..items[11]..', '..items[12]..', '..items[13]..', '..items[14]..', '
                    ..items[15]..', '..items[16]..', '..items[17]..', '..items[18]..');')
            until not sets_SQL:NextRow()
        end
    end

    -- keep the copy mails in the mailbox (core default is 30 days, after which GM mail is deleted with its items)
    cc_extendMailForItems(cc_newCharacter, mailedGuids)

    -- log what was mailed (with enchants/gems/suffix) so an admin can restore it later
    if cc_enableMailItemLog then
        local copyId = cc_nextCopyId()
        local sourceName = cc_characterNameByGuid(cc_playerGUID)
        local targetName = cc_newCharacterName or cc_characterNameByGuid(cc_newCharacter)
        for n,_ in ipairs(cc_oldItemGuids) do
            cc_logMailedItem(copyId, "copy", cc_playerGUID, sourceName, cc_newCharacter, targetName, cc_oldItemGuids[n], cc_newItemGuids[n], nil, nil)
        end
        for _, guid in ipairs(cc_totemItemGuids) do
            cc_logMailedItem(copyId, "copy", cc_playerGUID, sourceName, cc_newCharacter, targetName, nil, guid, nil, nil)
        end
    end
    cc_totemMailGuids = {}
    cc_totemItemGuids = {}

    -- everything is written: unlock the new character and log the success
    cc_liftCarbonCopyBan(cc_newCharacter, CC_BAN_REASON_COPY)
    local doneTargetName = cc_newCharacterName or cc_characterNameByGuid(cc_newCharacter) or tostring(cc_newCharacter)
    cc_logPlayer(cc_copySourceName or cc_characterNameByGuid(cc_playerGUID), cc_playerGUID, doneTargetName, cc_newCharacter,
        cc_copySourceLevel, cc_copyTicketsBefore, cc_copyTicketsAfter, CC_STATUS_SUCCESS, "Character copied")

    -- tell the player a few seconds later, so the unlock has settled before they log out and pick the new character
    local doneSourceGuid = cc_playerGUID
    CreateLuaEvent(function()
        local copyingPlayer = doneSourceGuid ~= nil and GetPlayerByGUID(doneSourceGuid) or nil
        if copyingPlayer ~= nil then
            copyingPlayer:SendBroadcastMessage(cc_t(copyingPlayer, "COPY_COMPLETE", doneTargetName))
        end
    end, cc_doneMessageDelay * 1000, 1)

    PrintInfo("2) Item enchants/gems copied for new character with GUID "..cc_newCharacter);
    cc_copySourceName = nil
    cc_copySourceLevel = nil
    cc_copyAccountId = nil
    cc_copyCharged = 0
    cc_copyMailed = false
    cc_copyStartedAt = nil
    cc_newCharacter = 0
    cc_newCharacterName = nil
    cc_copyTicketsBefore = nil
    cc_copyTicketsAfter = nil
    cc_oldItemGuids = {}
    cc_newItemGuids = {}
    cc_copyToken = cc_copyToken + 1
    cc_scriptIsBusy = 0
    cc_playerGUID = nil
end

function cc_splitString(inputstr, seperator)
    if seperator == nil then
        seperator = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..seperator.."]+)") do
        table.insert(t, str)
    end
    return t
end

function cc_normalizeCharacterName(name)
    if name == nil then
        return nil
    end

    local normalised = string.lower(name)
    normalised = normalised:gsub("^%l", string.upper)
    return normalised
end

function cc_has_value (tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end
    return false
end

function cc_resumeSubRoutine(eventId, delay, repeats)
    if cc_subRoutine == nil then
        RemoveEventById(eventId)
        return
    end
    local ok, err = coroutine.resume(cc_subRoutine)
    if not ok then
        RemoveEventById(eventId)
        cc_subRoutine = nil
        cc_copyFailed("copy", err)
    elseif coroutine.status(cc_subRoutine) == "dead" then
        RemoveEventById(eventId)
        cc_subRoutine = nil
    end
end

local PLAYER_EVENT_ON_COMMAND = 42
local PLAYER_EVENT_ON_LOGOUT = 4

-- The copy runs on a timer, not on the player, so it finishes even if the source player logs out.
-- The lock is only released when it is done (or by cc_copyFailed), so a second copy can't start in between.
local function cc_OnPlayerLogout(event, player)
    if cc_scriptIsBusy ~= 0 and cc_playerGUID ~= nil and tonumber(tostring(player:GetGUID())) == cc_playerGUID then
        PrintInfo("CarbonCopy: source player (GUID "..cc_playerGUID..") logged out mid-copy. The copy continues.")
    end
end

-- function to be called when the command hook fires
-- automatic cleanup of old mailed-items log rows (Config.mailItemLogRetentionDays: -1 = as long as the mails, 0 = never)
if cc_enableMailItemLog and cc_mailLogRetentionDays > 0 then
    local function cc_autoCleanup()
        local count = cc_cleanupMailLog(cc_mailLogRetentionDays)
        if count > 0 then
            PrintInfo("CarbonCopy: deleted "..count.." mailed-items log row(s) older than "..cc_mailLogRetentionDays.." day(s).")
        end
    end
    cc_autoCleanup()
    CreateLuaEvent(cc_autoCleanup, 86400000, 0)
end

-- Starter tickets belong to the account. Whenever the account creates a character (character screen) or enters the
-- world with any character, it gets Config.freeTickets (as it is at that moment) if it never got them
-- (cc_ensureStarterTickets). Existing balances are only ever added to. (mod-ale has no account-login event, and at the character screen there is no
-- player to tell which account it is, so these two are the account checks Lua can do.)
local PLAYER_EVENT_ON_CHARACTER_CREATE = 1
local PLAYER_EVENT_ON_LOGIN = 3
local function cc_grantStarterTickets(event, player)
    cc_ensureStarterTickets(player:GetAccountId(), player,
        event == PLAYER_EVENT_ON_CHARACTER_CREATE and "Starter tickets granted at character creation" or "Starter tickets granted at login")
end

RegisterPlayerEvent(PLAYER_EVENT_ON_COMMAND, cc_CopyCharacter)
RegisterPlayerEvent(PLAYER_EVENT_ON_CHARACTER_CREATE, cc_grantStarterTickets)
RegisterPlayerEvent(PLAYER_EVENT_ON_LOGIN, cc_grantStarterTickets)
RegisterPlayerEvent(PLAYER_EVENT_ON_LOGOUT, cc_OnPlayerLogout)
