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
--               -  add this script to ../lua_scripts/
--               -  grant account related tickets in the `carboncopy` table
-- PLAYER USAGE: 1) create a new character with same class/race as the one to copy in the same account. Do NOT log it in
--               2) log in with the source character
--               3) .carboncopy newToonsName
------------------------------------------------------------------------------------------------

local CarbonCopyConfig = require("CarbonCopy_Config")
local Config = CarbonCopyConfig.Config
local cc_maps = CarbonCopyConfig.cc_maps
local ticket_Cost = CarbonCopyConfig.ticket_Cost

-- Fallback / compatibility defaults for older configs.
local cc_carboncopyTable = Config.carboncopyTableName or "carboncopy"
local cc_playerLogsTable = Config.playerLogsTableName or "carboncopy_player_logs"
local cc_adminLogsTable = Config.adminLogsTableName or "carboncopy_admin_logs"
local cc_enablePlayerLogs = Config.enablePlayerLogs ~= false
local cc_enableAdminLogs = Config.enableAdminLogs ~= false


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

-- If module runs for the first time, create the db specified in Config.dbName and add the "carboncopy" table to it.
CharDBQuery('CREATE DATABASE IF NOT EXISTS `'..Config.customDbName..'`;');
CharDBQuery('CREATE TABLE IF NOT EXISTS `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` ('
    ..'`account_id` INT(11) NOT NULL, '
    ..'`tickets` INT(11) DEFAULT 0, '
    ..'`allow_copy_from_id` INT(11) DEFAULT 0, '
    ..'PRIMARY KEY (`account_id`)'
    ..') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DEFAULT;'
)

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
        ..'`action_code` TINYINT UNSIGNED NOT NULL COMMENT "3=GM_ADD,4=GM_REMOVE,5=GM_LOOKUP", '
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

local function cc_sqlQuote(value)
    if value == nil then
        return "NULL"
    end

    local escaped = tostring(value):gsub("\\", "\\\\"):gsub("'", "''")
    return "'"..escaped.."'"
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
    chatHandler:SendSysMessage("===== CarbonCopy configuration =====")

    for _, key in ipairs(cc_sortedKeys(Config)) do
        local value = Config[key]
        if type(value) ~= "table" then
            chatHandler:SendSysMessage("  "..tostring(key).." = "..cc_formatDisplayValue(value))
        end
    end

    cc_sendTableDump(chatHandler, "  cc_maps:", cc_maps)
    cc_sendTableDump(chatHandler, "  ticket_Cost:", ticket_Cost)

    chatHandler:SendSysMessage("===================================")
end

-- cc_execLogsCommand: shared handler for ".carboncopy logs" from console or GM.
local function cc_execLogsCommand(chatHandler, commandArray, startIdx)
    -- Help subcommand
    local firstArg = commandArray[startIdx] and string.lower(commandArray[startIdx]) or nil
    if firstArg == "help" or firstArg == "--help" then
        chatHandler:SendSysMessage("===== .carboncopy logs flags (all optional) =====")
        chatHandler:SendSysMessage("  --source  name|guid   filter by source name or GUID")
        chatHandler:SendSysMessage("  --target  name|guid   filter by target name or GUID")
        chatHandler:SendSysMessage("  --day     YYYY-MM-DD  entries from this date only")
        chatHandler:SendSysMessage("  --code    N           filter by status code:")
        chatHandler:SendSysMessage("                          0=free ticket  1=success  2=failed")
        chatHandler:SendSysMessage("  --limit   N           max rows 1-100 (default 20)")
        chatHandler:SendSysMessage("  --oldest              sort oldest-first (default: newest)")
        chatHandler:SendSysMessage("================================================")
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
                    chatHandler:SendSysMessage("--code must be a non-negative number. Code filter ignored.")
                end
            end
        elseif flag == "--limit" then
            i = i + 1
            if commandArray[i] ~= nil then
                local n = tonumber(commandArray[i])
                if n ~= nil and n >= 1 and n <= 100 then
                    limitN = math.floor(n)
                else
                    chatHandler:SendSysMessage("--limit must be 1-100. Using default 20.")
                end
            end
        elseif flag == "--oldest" then
            orderOldest = true
        else
            chatHandler:SendSysMessage("Unknown flag: "..commandArray[i]..". Use 'help' or '--help' for usage.")
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
            chatHandler:SendSysMessage("--day must be YYYY-MM-DD. Day filter ignored.")
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
    chatHandler:SendSysMessage("========== CarbonCopy Player Logs ==========")
    chatHandler:SendSysMessage("Filters: "..filterSummary.."  |  limit:"..limitN.."  |  "..(orderOldest and "oldest first" or "newest first"))
    chatHandler:SendSysMessage("  Time (MM-DD HH:MM)  Source (guid) [lv]  ->  Target (guid)  tix:before=>after  Reason")
    chatHandler:SendSysMessage("--------------------------------------------")

    local rows = CharDBQuery(sql)
    if rows == nil then
        chatHandler:SendSysMessage("  (no entries found matching the filters)")
        chatHandler:SendSysMessage("============================================")
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

    chatHandler:SendSysMessage("--------------------------------------------")
    chatHandler:SendSysMessage(count.." result(s)  |  limit "..limitN.."  |  "..(orderOldest and "oldest first" or "newest first"))
    chatHandler:SendSysMessage("============================================")
end

-- Player-facing texts for .carboncopy (no arguments), per client locale.
-- Locale IDs from player:GetDbcLocale(): 0=enUS 1=koKR 2=frFR 3=deDE 4=zhCN 5=zhTW 6=esES 7=esMX 8=ruRU
-- [0] (English) is used when a locale has no translation.
local cc_infoText = {
    TICKETS = {
        [0] = "You currently have %d tickets available for CarbonCopy.",
        [1] = "현재 CarbonCopy 티켓이 %d개 있습니다.",
        [2] = "Vous disposez actuellement de %d tickets CarbonCopy.",
        [3] = "Du hast derzeit %d CarbonCopy-Tickets.",
        [4] = "你当前拥有 %d 张 CarbonCopy 票券。",
        [5] = "你目前擁有 %d 張 CarbonCopy 票券。",
        [6] = "Actualmente tienes %d tickets de CarbonCopy.",
        [7] = "Actualmente tienes %d tickets de CarbonCopy.",
        [8] = "У вас %d жетонов CarbonCopy.",
    },
    USAGE = {
        [0] = "To copy this character: create a new character of the same race and class on this account (do NOT log it in), then type .carboncopy NewCharacterName while logged in on this character. You will be prompted when you can log in.",
        [1] = "이 캐릭터를 복사하려면: 같은 계정에 같은 종족과 직업의 새 캐릭터를 만드세요 (접속하지 마세요). 그다음 이 캐릭터로 접속한 상태에서 .carboncopy 새캐릭터이름 을 입력하세요. 접속해도 될 때 안내 메시지가 표시됩니다.",
        [2] = "Pour copier ce personnage : créez un nouveau personnage de même race et classe sur ce compte (ne vous connectez PAS avec), puis tapez .carboncopy NomDuNouveauPersonnage en étant connecté sur ce personnage. Un message vous indiquera quand vous pourrez vous connecter.",
        [3] = "So kopierst du diesen Charakter: Erstelle auf diesem Account einen neuen Charakter mit gleicher Rasse und Klasse (NICHT einloggen), dann tippe .carboncopy NeuerCharakterName, während du mit diesem Charakter eingeloggt bist. Du wirst benachrichtigt, sobald du dich einloggen kannst.",
        [4] = "复制此角色：在本账号创建一个相同种族和职业的新角色（不要登录它），然后在此角色登录时输入 .carboncopy 新角色名。可以登录时会提示你。",
        [5] = "複製此角色：在本帳號建立一個相同種族和職業的新角色（不要登入它），然後在此角色登入時輸入 .carboncopy 新角色名稱。可以登入時會提示你。",
        [6] = "Para copiar este personaje: crea un personaje nuevo de la misma raza y clase en esta cuenta (NO entres con él) y escribe .carboncopy NombreNuevoPersonaje mientras estás conectado con este personaje. Se te avisará cuando puedas conectarte.",
        [7] = "Para copiar este personaje: crea un personaje nuevo de la misma raza y clase en esta cuenta (NO entres con él) y escribe .carboncopy NombreNuevoPersonaje mientras estás conectado con este personaje. Se te avisará cuando puedas conectarte.",
        [8] = "Чтобы скопировать этого персонажа: создайте на этом аккаунте нового персонажа той же расы и класса (НЕ заходите им), затем введите .carboncopy ИмяНовогоПерсонажа, находясь в игре этим персонажем. Вам сообщат, когда можно будет войти.",
    },
    ELIGIBLE = {
        [0] = "This character (level %d) can be copied for %d ticket(s).",
        [1] = "이 캐릭터(레벨 %d)는 티켓 %d개로 복사할 수 있습니다.",
        [2] = "Ce personnage (niveau %d) peut être copié pour %d ticket(s).",
        [3] = "Dieser Charakter (Stufe %d) kann für %d Ticket(s) kopiert werden.",
        [4] = "此角色（%d 级）可以用 %d 张票券复制。",
        [5] = "此角色（%d 級）可以用 %d 張票券複製。",
        [6] = "Este personaje (nivel %d) se puede copiar por %d ticket(s).",
        [7] = "Este personaje (nivel %d) se puede copiar por %d ticket(s).",
        [8] = "Этого персонажа (уровень %d) можно скопировать за %d жетон(ов).",
    },
    NOT_ENOUGH_TICKETS = {
        [0] = "This character (level %d) needs %d ticket(s) to be copied, but you only have %d.",
        [1] = "이 캐릭터(레벨 %d)를 복사하려면 티켓 %d개가 필요하지만 %d개만 있습니다.",
        [2] = "Ce personnage (niveau %d) nécessite %d ticket(s) pour être copié, mais vous n'en avez que %d.",
        [3] = "Dieser Charakter (Stufe %d) braucht %d Ticket(s) zum Kopieren, du hast aber nur %d.",
        [4] = "复制此角色（%d 级）需要 %d 张票券，但你只有 %d 张。",
        [5] = "複製此角色（%d 級）需要 %d 張票券，但你只有 %d 張。",
        [6] = "Este personaje (nivel %d) necesita %d ticket(s) para copiarse, pero solo tienes %d.",
        [7] = "Este personaje (nivel %d) necesita %d ticket(s) para copiarse, pero solo tienes %d.",
        [8] = "Для копирования этого персонажа (уровень %d) нужно %d жетон(ов), а у вас только %d.",
    },
    LEVEL_TOO_HIGH = {
        [0] = "This character can't be copied: level %d is above the maximum level %d.",
        [1] = "이 캐릭터는 복사할 수 없습니다: 레벨 %d은(는) 최대 레벨 %d보다 높습니다.",
        [2] = "Ce personnage ne peut pas être copié : le niveau %d dépasse le niveau maximum %d.",
        [3] = "Dieser Charakter kann nicht kopiert werden: Stufe %d liegt über der Höchststufe %d.",
        [4] = "此角色无法复制：%d 级超过了最高等级 %d。",
        [5] = "此角色無法複製：%d 級超過了最高等級 %d。",
        [6] = "Este personaje no se puede copiar: el nivel %d supera el nivel máximo %d.",
        [7] = "Este personaje no se puede copiar: el nivel %d supera el nivel máximo %d.",
        [8] = "Этого персонажа нельзя скопировать: уровень %d выше максимального уровня %d.",
    },
    WRONG_MAP = {
        [0] = "You can only copy outside of dungeons, raids, battlegrounds and arenas.",
        [1] = "던전, 공격대, 전장, 투기장 밖에서만 복사할 수 있습니다.",
        [2] = "Vous ne pouvez copier qu'en dehors des donjons, raids, champs de bataille et arènes.",
        [3] = "Kopieren ist nur außerhalb von Dungeons, Schlachtzügen, Schlachtfeldern und Arenen möglich.",
        [4] = "只能在地下城、团队副本、战场和竞技场之外复制。",
        [5] = "只能在地城、團隊副本、戰場和競技場之外複製。",
        [6] = "Solo puedes copiar fuera de mazmorras, bandas, campos de batalla y arenas.",
        [7] = "Solo puedes copiar fuera de mazmorras, bandas, campos de batalla y arenas.",
        [8] = "Копировать можно только вне подземелий, рейдов, полей боя и арен.",
    },
    COSTS_HEADER = {
        [0] = "Ticket costs:",
        [1] = "티켓 비용:",
        [2] = "Coût en tickets :",
        [3] = "Ticketkosten:",
        [4] = "票券花费：",
        [5] = "票券花費：",
        [6] = "Coste en tickets:",
        [7] = "Costo en tickets:",
        [8] = "Стоимость в жетонах:",
    },
    COST_RANGE = {
        [0] = "  Level %d - %d = %d ticket(s)",
        [1] = "  레벨 %d - %d = 티켓 %d개",
        [2] = "  Niveau %d - %d = %d ticket(s)",
        [3] = "  Stufe %d - %d = %d Ticket(s)",
        [4] = "  %d - %d 级 = %d 张票券",
        [5] = "  %d - %d 級 = %d 張票券",
        [6] = "  Nivel %d - %d = %d ticket(s)",
        [7] = "  Nivel %d - %d = %d ticket(s)",
        [8] = "  Уровень %d - %d = %d жетон(ов)",
    },
    COST_LEVEL = {
        [0] = "  Level %d = %d ticket(s)",
        [1] = "  레벨 %d = 티켓 %d개",
        [2] = "  Niveau %d = %d ticket(s)",
        [3] = "  Stufe %d = %d Ticket(s)",
        [4] = "  %d 级 = %d 张票券",
        [5] = "  %d 級 = %d 張票券",
        [6] = "  Nivel %d = %d ticket(s)",
        [7] = "  Nivel %d = %d ticket(s)",
        [8] = "  Уровень %d = %d жетон(ов)",
    },
    COST_SINGLE = {
        [0] = "  Every copy = 1 ticket",
        [1] = "  복사 1회 = 티켓 1개",
        [2] = "  Chaque copie = 1 ticket",
        [3] = "  Jede Kopie = 1 Ticket",
        [4] = "  每次复制 = 1 张票券",
        [5] = "  每次複製 = 1 張票券",
        [6] = "  Cada copia = 1 ticket",
        [7] = "  Cada copia = 1 ticket",
        [8] = "  Каждое копирование = 1 жетон",
    },
    STARTER_TICKETS = {
        [0] = "Starter tickets = %d",
        [1] = "기본 지급 티켓 = %d",
        [2] = "Tickets de départ = %d",
        [3] = "Starttickets = %d",
        [4] = "初始票券 = %d",
        [5] = "初始票券 = %d",
        [6] = "Tickets iniciales = %d",
        [7] = "Tickets iniciales = %d",
        [8] = "Стартовые жетоны = %d",
    },
}

-- Picks the text for the player's client locale (English if missing) and fills in the values.
local function cc_info(player, key, ...)
    local entry = cc_infoText[key]
    local text = entry[player and player:GetDbcLocale() or 0] or entry[0]
    if select('#', ...) > 0 then
        return string.format(text, ...)
    end
    return text
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

function cc_CopyCharacter(event, player, command, chatHandler)

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

    if cc_scriptIsBusy ~= 0 then
        local reason = "The server is currently busy. Please try again in a few seconds."
        chatHandler:SendSysMessage(reason)
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
            if commandArray[3] == nil then
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
                cc_resetVariables()
                return false
            end

            local ticketsAction = string.lower(commandArray[3])
            if ticketsAction == "add" then
                if commandArray[4] == nil or commandArray[5] == nil then
                    chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
                    cc_resetVariables()
                    return false
                end

                if tonumber(commandArray[5]) == nil or tonumber(commandArray[5]) > 1000 or tonumber(commandArray[5]) < 0 then
                    chatHandler:SendSysMessage("Too large or negative amount chosen for .carboncopy tickets add: "..commandArray[5]..". Max allowed is +1000.")
                    cc_resetVariables()
                    return false
                end

                local normalisedCharacterName = cc_normalizeCharacterName(commandArray[4])
                local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;")
                local accountId
                local oldTickets
                if Data_SQL ~= nil then
                    accountId = Data_SQL:GetUInt32(0)
                else
                    local reason = "Player name not found. Syntax: .carboncopy tickets add $characterName $amount"
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, nil, nil, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' LIMIT 1;')
                if Data_SQL ~= nil then
                    oldTickets = Data_SQL:GetUInt32(0)
                else
                    oldTickets = 0
                end

                if oldTickets >= 1000 or oldTickets < 0 then
                    local reason = "Too large total amount tickets: "..commandArray[5]..". Max allowed total is +1000. Current value: "..oldTickets
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                CharDBQuery('DELETE FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..';')
                CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..accountId..', '..commandArray[5] + oldTickets..', 0);')
                chatHandler:SendSysMessage("The console has sucessfully used the .carboncopy tickets add command, adding "..commandArray[5].." tickets to the account "..accountId.." which belongs to player "..normalisedCharacterName..".")
                cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + tonumber(commandArray[5]), CC_STATUS_SUCCESS, "Console .carboncopy tickets add "..normalisedCharacterName.." "..commandArray[5])
                cc_resetVariables()
                return false
            end

            if ticketsAction == "remove" then
                if commandArray[4] == nil or commandArray[5] == nil then
                    chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
                    cc_resetVariables()
                    return false
                end

                if tonumber(commandArray[5]) == nil or tonumber(commandArray[5]) > 1000 or tonumber(commandArray[5]) < 0 then
                    chatHandler:SendSysMessage("Too large or negative amount chosen for .carboncopy tickets remove: "..commandArray[5]..". Max allowed is +1000.")
                    cc_resetVariables()
                    return false
                end

                local normalisedCharacterName = cc_normalizeCharacterName(commandArray[4])
                local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;")
                local accountId
                local oldTickets
                if Data_SQL ~= nil then
                    accountId = Data_SQL:GetUInt32(0)
                else
                    local reason = "Player name not found. Syntax: .carboncopy tickets remove $characterName $amount"
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_REMOVE, nil, nil, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' LIMIT 1;')
                if Data_SQL ~= nil then
                    oldTickets = Data_SQL:GetUInt32(0)
                else
                    oldTickets = 0
                end

                if oldTickets <= 0 or oldTickets < tonumber(commandArray[5]) then
                    local reason = "The account does not have enough tickets to remove "..commandArray[5]..". Current value: "..oldTickets
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_REMOVE, oldTickets, oldTickets, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                CharDBQuery('DELETE FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..';')
                CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..accountId..', '..oldTickets - commandArray[5]..', 0);')
                chatHandler:SendSysMessage("The console has sucessfully used the .carboncopy tickets remove command, removing "..commandArray[5].." tickets from the account "..accountId.." which belongs to player "..normalisedCharacterName..".")
                cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_REMOVE, oldTickets, oldTickets - tonumber(commandArray[5]), CC_STATUS_SUCCESS, "Console .carboncopy tickets remove "..normalisedCharacterName.." "..commandArray[5])
                cc_resetVariables()
                return false
            end

            if ticketsAction ~= "lookup" then
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
                cc_resetVariables()
                return false
            end

            local lookupNameArg = commandArray[4]
            if lookupNameArg == nil then
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
                cc_resetVariables()
                return false
            end

            local lookupCharacterName = cc_normalizeCharacterName(lookupNameArg)
            local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(lookupCharacterName).." LIMIT 1;")
            if Data_SQL == nil then
                local reason = "Character name not found. Check spelling."
                chatHandler:SendSysMessage(reason)
                cc_logAdmin("console", nil, lookupCharacterName, nil, nil, CC_ACTION_GM_LOOKUP, nil, nil, CC_STATUS_FAILED, reason)
                cc_resetVariables()
                return false
            end

            local lookupAccountId = Data_SQL:GetUInt32(0)
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..lookupAccountId..' LIMIT 1;')
            local lookupTickets
            if Data_SQL ~= nil then
                lookupTickets = Data_SQL:GetUInt32(0)
            else
                lookupTickets = Config.freeTickets
            end

            chatHandler:SendSysMessage("CarbonCopy tickets for "..lookupCharacterName.." (account "..lookupAccountId.."): "..lookupTickets)
            cc_logAdmin("console", nil, lookupCharacterName, nil, nil, CC_ACTION_GM_LOOKUP, lookupTickets, lookupTickets, CC_STATUS_SUCCESS, "Console .carboncopy tickets lookup "..lookupCharacterName)
            cc_resetVariables()
            return false
        end

        if player == nil and ccSubCommandConsole == "logs" then
            cc_execLogsCommand(chatHandler, commandArray, 3)
            cc_resetVariables()
            return false
        end

        if player == nil and (ccSubCommandConsole == "config" or ccSubCommandConsole == "settings") then
            cc_execConfigCommand(chatHandler)
            cc_resetVariables()
            return false
        end

        -- console / SOAP: list the commands that work from here
        if player == nil and (ccSubCommandConsole == "help" or ccSubCommandConsole == "--help") then
            chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
            chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
            chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
            chatHandler:SendSysMessage("Syntax: .carboncopy config")
            chatHandler:SendSysMessage("Syntax: .carboncopy logs [--source name|guid] [--target name|guid] [--day YYYY-MM-DD] [--code N] [--limit N] [--oldest]")
            chatHandler:SendSysMessage("Syntax: .addcctickets $characterName $amount") -- Kept for Legacy / Compatibility
            chatHandler:SendSysMessage("Syntax: CCACCOUNTTICKETS $accountName $amount")
            chatHandler:SendSysMessage(".carboncopy $newCharacterName can only be run in game, from the character to copy.")
            cc_resetVariables()
            return false
        end

        if player == nil then
            local reason = "This command can not be run from the console, but only from the character to copy."
            chatHandler:SendSysMessage(reason)
            chatHandler:SendSysMessage("Syntax: .addcctickets $characterName $amount") -- Kept for Legacy / Compatibility
            return false
        end
        -- make sure the player is properly ranked
        if player:GetGMRank() < Config.minGMRankForCopy then
            local reason = "You lack permisisions to execute this command."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), nil, nil, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end

        -- provide syntax help (GM only, it lists the GM ticket/config/logs commands)
        if commandArray[2] == "help" then
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage("You lack permisisions to execute this command.")
                cc_resetVariables()
                return false
            end
            chatHandler:SendSysMessage("Syntax: .carboncopy $newCharacterName")
            chatHandler:SendSysMessage("Syntax: .carboncopy config")
            chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
            chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
            chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
            chatHandler:SendSysMessage("Syntax: .carboncopy logs [--source name|guid] [--target name|guid] [--day YYYY-MM-DD] [--limit N] [--oldest]")
            cc_resetVariables()
            return false
        end

        -- print the available tickets
        local accountId = player:GetAccountId()
        local _ticketsAtEntrySQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' LIMIT 1;')
        local ticketsAtEntry = _ticketsAtEntrySQL ~= nil and _ticketsAtEntrySQL:GetUInt32(0) or Config.freeTickets
        _ticketsAtEntrySQL = nil
        if commandArray[2] == nil then
            local Data_SQL
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' LIMIT 1;');
            if Data_SQL  ~= nil then
                oldTickets = Data_SQL:GetUInt32(0)
                cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), oldTickets, oldTickets, CC_STATUS_SUCCESS, "Ticket balance lookup")
            else
                oldTickets = Config.freeTickets
                CharDBExecute('REPLACE INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..accountId..', '..Config.freeTickets..', 0) ;')
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

            cc_resetVariables()
            return false
        end

        local ccSubCommand = string.lower(commandArray[2])
        if ccSubCommand == "config" or ccSubCommand == "settings" then
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage("You lack permisisions to execute this command.")
                cc_resetVariables()
                return false
            end

            cc_execConfigCommand(chatHandler)
            cc_resetVariables()
            return false
        end

        if ccSubCommand == "tickets" then
            -- every tickets action (lookup / add / remove / syntax) is GM only
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage("You lack permisisions to execute this command.")
                cc_resetVariables()
                return false
            end

            if commandArray[3] == nil then
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
                cc_resetVariables()
                return false
            end

            local ticketsAction = string.lower(commandArray[3])
            if ticketsAction == "add" then
                if player:GetGMRank() < Config.minGMRankForTickets then
                    chatHandler:SendSysMessage("You lack permisisions to execute this command.")
                    cc_resetVariables()
                    return false
                end

                if commandArray[4] == nil or commandArray[5] == nil then
                    chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
                    cc_resetVariables()
                    return false
                end

                if tonumber(commandArray[5]) == nil or tonumber(commandArray[5]) > 1000 or tonumber(commandArray[5]) < 0 then
                    chatHandler:SendSysMessage("Too large or negative amount chosen for .carboncopy tickets add: "..commandArray[5]..". Max allowed is +1000.")
                    cc_resetVariables()
                    return false
                end

                local normalisedCharacterName = cc_normalizeCharacterName(commandArray[4])
                local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;")
                local addAccountId
                local oldTickets
                if Data_SQL ~= nil then
                    addAccountId = Data_SQL:GetUInt32(0)
                else
                    local reason = "Player name not found. Syntax: .carboncopy tickets add $characterName $amount"
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, nil, nil, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..addAccountId..' LIMIT 1;')
                if Data_SQL ~= nil then
                    oldTickets = Data_SQL:GetUInt32(0)
                else
                    oldTickets = 0
                end

                if oldTickets >= 1000 or oldTickets < 0 then
                    local reason = "Too large total amount tickets: "..commandArray[5]..". Max allowed total is +1000. Current value: "..oldTickets
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                CharDBQuery('DELETE FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..addAccountId..';')
                CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..addAccountId..', '..commandArray[5] + oldTickets..', 0);')
                chatHandler:SendSysMessage("GM "..player:GetName().. " has sucessfully used the .carboncopy tickets add command, adding "..commandArray[5].." tickets to the account "..addAccountId.." which belongs to player "..normalisedCharacterName..".")
                cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + tonumber(commandArray[5]), CC_STATUS_SUCCESS, "GM .carboncopy tickets add")
                cc_resetVariables()
                return false
            end

            if ticketsAction == "remove" then
                if player:GetGMRank() < Config.minGMRankForTickets then
                    chatHandler:SendSysMessage("You lack permisisions to execute this command.")
                    cc_resetVariables()
                    return false
                end

                if commandArray[4] == nil or commandArray[5] == nil then
                    chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
                    cc_resetVariables()
                    return false
                end

                if tonumber(commandArray[5]) == nil or tonumber(commandArray[5]) > 1000 or tonumber(commandArray[5]) < 0 then
                    chatHandler:SendSysMessage("Too large or negative amount chosen for .carboncopy tickets remove: "..commandArray[5]..". Max allowed is +1000.")
                    cc_resetVariables()
                    return false
                end

                local normalisedCharacterName = cc_normalizeCharacterName(commandArray[4])
                local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;")
                local removeAccountId
                local oldTickets
                if Data_SQL ~= nil then
                    removeAccountId = Data_SQL:GetUInt32(0)
                else
                    local reason = "Player name not found. Syntax: .carboncopy tickets remove $characterName $amount"
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_REMOVE, nil, nil, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..removeAccountId..' LIMIT 1;')
                if Data_SQL ~= nil then
                    oldTickets = Data_SQL:GetUInt32(0)
                else
                    oldTickets = 0
                end

                if oldTickets <= 0 or oldTickets < tonumber(commandArray[5]) then
                    local reason = "The account does not have enough tickets to remove "..commandArray[5]..". Current value: "..oldTickets
                    chatHandler:SendSysMessage(reason)
                    cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_REMOVE, oldTickets, oldTickets, CC_STATUS_FAILED, reason)
                    cc_resetVariables()
                    return false
                end

                CharDBQuery('DELETE FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..removeAccountId..';')
                CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..removeAccountId..', '..oldTickets - commandArray[5]..', 0);')
                chatHandler:SendSysMessage("GM "..player:GetName().. " has sucessfully used the .carboncopy tickets remove command, removing "..commandArray[5].." tickets from the account "..removeAccountId.." which belongs to player "..normalisedCharacterName..".")
                cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_REMOVE, oldTickets, oldTickets - tonumber(commandArray[5]), CC_STATUS_SUCCESS, "GM .carboncopy tickets remove")
                cc_resetVariables()
                return false
            end

            if ticketsAction ~= "lookup" then
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets add $characterName $amount")
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets remove $characterName $amount")
                cc_resetVariables()
                return false
            end

            local lookupNameArg = commandArray[4]
            if lookupNameArg == nil then
                chatHandler:SendSysMessage("Syntax: .carboncopy tickets lookup $characterName")
                cc_resetVariables()
                return false
            end

            local lookupCharacterName = cc_normalizeCharacterName(lookupNameArg)
            local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(lookupCharacterName).." LIMIT 1;")
            if Data_SQL == nil then
                local reason = "Character name not found. Check spelling."
                chatHandler:SendSysMessage(reason)
                cc_logAdmin(sourceName, sourceGuid, lookupCharacterName, nil, nil, CC_ACTION_GM_LOOKUP, nil, nil, CC_STATUS_FAILED, reason)
                cc_resetVariables()
                return false
            end

            local lookupAccountId = Data_SQL:GetUInt32(0)
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..lookupAccountId..' LIMIT 1;')
            local lookupTickets
            if Data_SQL ~= nil then
                lookupTickets = Data_SQL:GetUInt32(0)
            else
                lookupTickets = Config.freeTickets
            end

            chatHandler:SendSysMessage("CarbonCopy tickets for "..lookupCharacterName.." (account "..lookupAccountId.."): "..lookupTickets)
            cc_logAdmin(sourceName, sourceGuid, lookupCharacterName, nil, nil, CC_ACTION_GM_LOOKUP, lookupTickets, lookupTickets, CC_STATUS_SUCCESS, "GM .carboncopy tickets lookup")
            cc_resetVariables()
            return false
        end

        if ccSubCommand == "logs" then
            if player:GetGMRank() < Config.minGMRankForTickets then
                chatHandler:SendSysMessage("You lack permissions to execute this command.")
                cc_resetVariables()
                return false
            end
            cc_execLogsCommand(chatHandler, commandArray, 3)
            cc_resetVariables()
            return false
        end

        -- check maxLevel
        if player:GetLevel() > Config.maxLevel then
            local reason = "The character you want to copy from is too high level. Max level is "..Config.maxLevel..". Aborting."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, nil, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end

        cc_playerGUID = tostring(player:GetGUID())
        cc_playerGUID = tonumber(cc_playerGUID)
        local targetName = cc_normalizeCharacterName(commandArray[2])

        --check for target character to be on same account
        local Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(targetName).." LIMIT 1;");
        if Data_SQL == nil then
            local reason = "Name not found. Check spelling. Aborting."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, targetName, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end
        local targetAccountId = Data_SQL:GetUInt32(0)
        Data_SQL = nil
        if targetAccountId ~= accountId then
            local reason = "The requested character is not on the same account. Aborting."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, targetName, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end

        local Data_SQL = CharDBQuery("SELECT `guid` FROM `characters` WHERE `name` = "..cc_sqlQuote(targetName).." LIMIT 1;");
        local newCharacter
        if Data_SQL ~= nil then
            newCharacter = Data_SQL:GetUInt32(0)
       	else
            local reason = "Name not found. Check spelling. Aborting."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, targetName, nil, player:GetLevel(), ticketsAtEntry, ticketsAtEntry, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end
        Data_SQL = nil

        --check for available tickets
        local Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..';');
        local availableTickets
        local requiredTickets
        if Data_SQL ~= nil then
            availableTickets = Data_SQL:GetUInt32(0)
            Data_SQL = nil
        else
            CharDBExecute('REPLACE INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..accountId..', '..Config.freeTickets..', 0) ;')
            availableTickets = Config.freeTickets
        end

        if Config.ticketCost == "single" then
            if availableTickets ~= nil and availableTickets <= 0 then
                local reason = "You do not have enough Carbon Copy tickets to execute this command. Aborting."
                chatHandler:SendSysMessage(reason)
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                cc_resetVariables()
                return false
            end
            requiredTickets = 1
        elseif Config.ticketCost == "level" then
            local Data_SQL = CharDBQuery('SELECT `level` FROM `characters` WHERE `guid` = '..cc_playerGUID..' LIMIT 1;');
            local n = Data_SQL:GetUInt8(0) - 1
            repeat
                n = n + 1
            until ticket_Cost[n] ~= nil
            requiredTickets = ticket_Cost[n]
            if availableTickets ~= nil and availableTickets <= 0 then
                local reason = "You do not have enough Carbon Copy tickets to execute this command. Aborting."
                chatHandler:SendSysMessage(reason)
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                cc_resetVariables()
                return false
            end
            if availableTickets < requiredTickets then
                local reason = "You do not have enough Carbon Copy tickets to execute this command. Aborting."
                chatHandler:SendSysMessage(reason)
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                cc_resetVariables()
                return false
            end
            Data_SQL = nil
        else
            PrintError("Unhandled exception in CarbonCopy. Config.ticketCost is neither set to \"single\" nor \"level\".")
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
            local reason = "The requested character is not the same race as this character. Aborting."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end
        if sourceClass ~= targetClass then
            local reason = "The requested character is not the same class as this character. Aborting."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end

        -- check if target character wasn't logged in
        local cc_cinematic
        local Data_SQL = CharDBQuery('SELECT cinematic FROM characters WHERE guid = '..newCharacter..';');
        if Data_SQL ~= nil then
            cc_cinematic = Data_SQL:GetUInt16(0)
            if cc_cinematic == 1 then
                local reason = "The requested character has been logged in already (or has already been Carbon Copied). Aborting."
                chatHandler:SendSysMessage(reason)
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                cc_cinematic = nil
                cc_resetVariables()
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
                local reason = "The requested character has been logged in already (or has already been Carbon Copied). Aborting."
                chatHandler:SendSysMessage(reason)
                cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
                cc_online = nil
                cc_resetVariables()
                return false
            end
        else
            PrintError("Unhandled exception in CarbonCopy. Could not read characters.online from cc_playerGUID "..newCharacter..".")
        end

        -- check source characters location
        local cc_mapId
        cc_mapId = player:GetMapId()
        if not cc_has_value(cc_maps, cc_mapId) then
            local reason = "You are not in an allowed map. Try again outside/not in a dungeon."
            chatHandler:SendSysMessage(reason)
            cc_logPlayer(sourceName, sourceGuid, targetName, newCharacter, player:GetLevel(), availableTickets, availableTickets, CC_STATUS_FAILED, reason)
            cc_resetVariables()
            return false
        end

        -------------- COPY SCRIPT STARTS HERE ---------------------
        --set Global variable to prevent simultaneous action and lock the target for 15 seconds
        Ban(1, targetName, 15, "CarbonCopy", "CarbonCopy" )
        cc_scriptIsBusy = 1
        cc_newCharacter = newCharacter
        cc_newCharacterName = targetName
        cc_copyTicketsBefore = availableTickets
        cc_copyTicketsAfter = availableTickets - requiredTickets

        -- save the source character to db to prevent recent changes from being not applied
        player:SaveToDB()

        --fetch all required variables before 1st yield
        cc_playerString = player:GetClassAsString(0)
        cc_logPlayer(sourceName, sourceGuid, targetName, cc_newCharacter, player:GetLevel(), availableTickets, availableTickets - requiredTickets, CC_STATUS_SUCCESS, "Copy started")
        PrintInfo("1) The player with GUID "..cc_playerGUID.." has succesfully initiated the .carboncopy command. Target character: "..cc_newCharacter);
        chatHandler:SendSysMessage("Copy started. You have been charged "..requiredTickets.." ticket(s) for this action. There are "..availableTickets - requiredTickets.." ticket()s left.")
        local stayMsgEnglish = "STAY logged in for one minute!"
        local stayMsgItalian = "RIMANI connesso per un minuto!"
        local locale = player:GetDbcLocale()
        local stayMsgByLocale = {
            [1] = "1분 동안 접속 상태를 유지하세요!",    -- koKR
            [2] = "RESTEZ connecte pendant une minute!", -- frFR
            [3] = "BLEIB eingeloggt für eine Minute!", -- deDE
            [4] = "请保持在线一分钟！",                    -- zhCN
            [5] = "請保持在線一分鐘！",                    -- zhTW
            [6] = "MANTENTE conectado por un minuto!", -- esES
            [7] = "MANTENTE conectado por un minuto!", -- esMX
            [8] = "ОСТАВАЙТЕСЬ В ИГРЕ ОДНУ МИНУТУ!"    -- ruRU
        }
        local localizedStayMsg = stayMsgByLocale[locale]

        -- Display English and Italian (as Italian doesn't have a locale in Wrath)
        chatHandler:SendSysMessage(stayMsgEnglish)
        chatHandler:SendSysMessage(stayMsgItalian)
        if localizedStayMsg ~= nil then
            chatHandler:SendSysMessage(localizedStayMsg)
        end

        cc_eventId = CreateLuaEvent(cc_resumeSubRoutine, 1000, 11)

        cc_subRoutine = coroutine.create(function ()

        -- deduct tickets
        if Config.ticketCost == "single" then
            local Data_SQL = CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` SET tickets = tickets -1 WHERE `account_id` = '..accountId..';');
            Data_SQL = nil
        elseif Config.ticketCost == "level" then
            local Data_SQL = CharDBQuery('UPDATE `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` SET tickets = tickets -'..requiredTickets..' WHERE `account_id` = '..accountId..';');
            Data_SQL = nil
        end

        -- delete TempTables
        cc_deleteTempTables(cc_playerGUID)

        -- Copy characters table
        local QueryString
        QueryString = 'UPDATE `characters` AS t1 '
        QueryString = QueryString..'INNER JOIN `characters` AS t2 ON t2.guid = '..cc_playerGUID..' '
        QueryString = QueryString..'SET t1.level = t2.level, t1.xp = t2.xp, t1.taximask = t2.taximask, '
        QueryString = QueryString..'t1.leveltime = t2.leveltime, t1.stable_slots = t2.stable_slots, t1.health = t2.health, '
        QueryString = QueryString..'t1.power1 = t2.power1, t1.power2 = t2.power2, t1.power3 = t2.power3, t1.power4 = t2.power4, '
        QueryString = QueryString..'t1.power5 = t2.power5, t1.power6 = t2.power6, t1.power7 = t2.power7, t1.talentGroupsCount = t2.talentGroupsCount, '
        QueryString = QueryString..'t1.exploredZones = t2.exploredZones WHERE t1.guid = '..cc_newCharacter..';'
        local Data_SQL = CharDBQuery(QueryString);
        QueryString = nil
        Data_SQL = nil
        local Data_SQL = CharDBQuery('UPDATE characters SET cinematic = 1 WHERE guid = '..cc_newCharacter..';');

        coroutine.yield()
        -- Copy achivements level ups 10, 20, 30, 40, 50, 60, 70 or 80 if they exist and use carboncopy sucess timestamp when it was "obtained".
        local level_achievements = {6, 7, 8, 9, 10, 11, 12, 13}
        local achievement_list = table.concat(level_achievements, ",")
        local Data_SQL = CharDBQuery('DELETE FROM character_achievement WHERE guid = '..cc_newCharacter..' AND achievement IN ('..achievement_list..');')
        local Data_SQL = CharDBQuery('INSERT INTO character_achievement (guid, achievement, date) SELECT '..cc_newCharacter..', achievement, UNIX_TIMESTAMP() FROM character_achievement WHERE guid = '..cc_playerGUID..' AND achievement IN ('..achievement_list..');')
        Data_SQL = nil

        coroutine.yield()
        -- Copy character_homebind
        local Data_SQL = CharDBQuery('DELETE FROM character_homebind WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_homebind VALUES ('..cc_newCharacter..' ,0,0,0,0,0);')
        QueryString = 'UPDATE character_homebind AS t1 INNER JOIN character_homebind AS t2 ON t2.guid = '..cc_playerGUID..' '
        QueryString = QueryString..'SET t1.mapId = t2.mapId, t1.zoneId = t2.zoneId, t1.posX = t2.posX, t1.posY = t2.posY, t1.posZ = t2.posZ '
        QueryString = QueryString..'WHERE t1.guid = '..cc_newCharacter..';'
        local Data_SQL = CharDBQuery(QueryString);
        QueryString = nil
        Data_SQL = nil

        -- Copy character_pet and totems
        if cc_playerString == "Hunter" then
            local Data_SQL = CharDBQuery('SELECT id FROM character_pet WHERE owner = '..cc_playerGUID..' LIMIT 1;');
            if Data_SQL ~= nil then
                cc_playerPetId = Data_SQL:GetUInt32(0)
                Data_SQL = nil

                local Data_SQL = CharDBQuery('SELECT MAX(id) FROM character_pet;');
                local cc_targetPetId = Data_SQL:GetUInt32(0) + 1
                Data_SQL = nil

                local Data_SQL = CharDBQuery('DELETE FROM character_pet WHERE owner = '..cc_newCharacter..';')
                local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempPet'..cc_playerGUID..' LIKE character_pet;')
                local Data_SQL = CharDBQuery('INSERT INTO tempPet'..cc_playerGUID..' SELECT * FROM character_pet WHERE id = '..cc_playerPetId..';')
                local Data_SQL = CharDBQuery('UPDATE tempPet'..cc_playerGUID..' SET id = '..cc_targetPetId..', slot = 0, owner = '..cc_newCharacter..';')
                local Data_SQL = CharDBQuery('INSERT INTO character_pet SELECT * FROM tempPet'..cc_playerGUID..';')
                local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempPet'..cc_playerGUID..';')

                QueryString = nil
                Data_SQL = nil

                local Data_SQL = CharDBQuery('DELETE FROM pet_spell WHERE guid = '..cc_targetPetId..';')
                local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempPet_spell'..cc_playerGUID..' LIKE pet_spell;')
                local Data_SQL = CharDBQuery('INSERT INTO tempPet_spell'..cc_playerGUID..' SELECT * FROM pet_spell WHERE guid = '..cc_playerPetId..';')
                local Data_SQL = CharDBQuery('UPDATE tempPet_spell'..cc_playerGUID..' SET guid = '..cc_targetPetId..' WHERE guid = '..cc_playerPetId..';')
                local Data_SQL = CharDBQuery('INSERT INTO pet_spell SELECT * FROM tempPet_spell'..cc_playerGUID..';')
                local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempPet_spell'..cc_playerGUID..';')
                QueryString = nil
                Data_SQL = nil
            end
        elseif cc_playerString == "Shaman" then
            local totemItem = {}
            totemItem[1] = 38
            totemItem[2] = 38
            totemItem[3] = 38
            totemItem[4] = 38
            totemItem[5] = 38
            local totemsDone = 0
            local Data_SQL
            Data_SQL = CharDBQuery('SELECT itemEntry FROM item_instance WHERE owner_guid = '..cc_playerGUID..' AND itemEntry = 5178 LIMIT 1;')
            if Data_SQL ~= nil then
                if Data_SQL:GetUInt16(0) == 5178 then
                    totemItem[4] = 5178
                end
            end
            Data_SQL = nil

            local Data_SQL
            Data_SQL = CharDBQuery('SELECT itemEntry FROM item_instance WHERE owner_guid = '..cc_playerGUID..' AND itemEntry = 5177 LIMIT 1;')
            if Data_SQL ~= nil then
                if Data_SQL:GetUInt16(0) == 5177 then
                    totemItem[3] = 5177
                end
            end
            Data_SQL = nil

            local Data_SQL
            Data_SQL = CharDBQuery('SELECT itemEntry FROM item_instance WHERE owner_guid = '..cc_playerGUID..' AND itemEntry = 5176 LIMIT 1;')
            if Data_SQL ~= nil then
                if Data_SQL:GetUInt16(0) == 5176 then
                    totemItem[2] = 5176
                end
            end
            Data_SQL = nil

            local Data_SQL
            Data_SQL = CharDBQuery('SELECT itemEntry FROM item_instance WHERE owner_guid = '..cc_playerGUID..' AND itemEntry = 5175 LIMIT 1;')
            if Data_SQL ~= nil then
                if Data_SQL:GetUInt16(0) == 5175 then
                    totemItem[1] = 5175
                end
            end
            Data_SQL = nil

            local Data_SQL
            Data_SQL = CharDBQuery('SELECT itemEntry FROM item_instance WHERE owner_guid = '..cc_playerGUID..' AND itemEntry = 46978 LIMIT 1;')
            if Data_SQL ~= nil then
                if Data_SQL:GetUInt16(0) == 46978 then
                    totemItem[5] = 46978
                end
            end
            Data_SQL = nil

            SendMail("Copied items", "Hello "..targetName..Config.mailText, cc_newCharacter, 0, 61, 0, 0, 0, totemItem[1], 1, totemItem[2], 1, totemItem[3], 1, totemItem[4], 1, totemItem[5], 1)

            Data_SQL = nil
            totemsDone = nil
        end

        coroutine.yield()
        --Copy quests
        local Data_SQL = CharDBQuery('DELETE FROM character_queststatus_rewarded WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempQuest'..cc_playerGUID..' LIKE character_queststatus_rewarded;')
        local Data_SQL = CharDBQuery('INSERT INTO tempQuest'..cc_playerGUID..' SELECT * FROM character_queststatus_rewarded WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('UPDATE tempQuest'..cc_playerGUID..' SET guid = '..cc_newCharacter..' WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_queststatus_rewarded SELECT * FROM tempQuest'..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempQuest'..cc_playerGUID..';')
        Data_SQL = nil

        coroutine.yield()
        --Copy reputation
        local Data_SQL = CharDBQuery('DELETE FROM character_reputation WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempReputation'..cc_playerGUID..' LIKE character_reputation;')
        local Data_SQL = CharDBQuery('INSERT INTO tempReputation'..cc_playerGUID..' SELECT * FROM character_reputation WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('UPDATE tempReputation'..cc_playerGUID..' SET guid = '..cc_newCharacter..' WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_reputation SELECT * FROM tempReputation'..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempReputation'..cc_playerGUID..';')
        Data_SQL = nil

        coroutine.yield()
        --Copy skills
        local Data_SQL = CharDBQuery('DELETE FROM character_skills WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempSkills'..cc_playerGUID..' LIKE character_skills;')
        local Data_SQL = CharDBQuery('INSERT INTO tempSkills'..cc_playerGUID..' SELECT * FROM character_skills WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('UPDATE tempSkills'..cc_playerGUID..' SET guid = '..cc_newCharacter..' WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_skills SELECT * FROM tempSkills'..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempSkills'..cc_playerGUID..';')
        Data_SQL = nil

        coroutine.yield()
        --Copy spells
        local Data_SQL = CharDBQuery('DELETE FROM character_spell WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempSpell'..cc_playerGUID..' LIKE character_spell;')
        local Data_SQL = CharDBQuery('INSERT INTO tempSpell'..cc_playerGUID..' SELECT * FROM character_spell WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('UPDATE tempSpell'..cc_playerGUID..' SET guid = '..cc_newCharacter..' WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_spell SELECT * FROM tempSpell'..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempSpell'..cc_playerGUID..';')
        Data_SQL = nil

        coroutine.yield()
        --Copy talents
        local Data_SQL = CharDBQuery('DELETE FROM character_talent WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempTalent'..cc_playerGUID..' LIKE character_talent;')
        local Data_SQL = CharDBQuery('INSERT INTO tempTalent'..cc_playerGUID..' SELECT * FROM character_talent WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('UPDATE tempTalent'..cc_playerGUID..' SET guid = '..cc_newCharacter..' WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_talent SELECT * FROM tempTalent'..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempTalent'..cc_playerGUID..';')
        Data_SQL = nil

        coroutine.yield()
        --Copy glyphs
        local Data_SQL = CharDBQuery('DELETE FROM character_glyphs WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempGlyphs'..cc_playerGUID..' LIKE character_glyphs;')
        local Data_SQL = CharDBQuery('INSERT INTO tempGlyphs'..cc_playerGUID..' SELECT * FROM character_glyphs WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('UPDATE tempGlyphs'..cc_playerGUID..' SET guid = '..cc_newCharacter..' WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_glyphs SELECT * FROM tempGlyphs'..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempGlyphs'..cc_playerGUID..';')
        Data_SQL = nil

        coroutine.yield()
        --Copy actions
        local Data_SQL = CharDBQuery('DELETE FROM character_action WHERE guid = '..cc_newCharacter..';')
        local Data_SQL = CharDBQuery('CREATE TEMPORARY TABLE tempAction'..cc_playerGUID..' LIKE character_action;')
        local Data_SQL = CharDBQuery('INSERT INTO tempAction'..cc_playerGUID..' SELECT * FROM character_action WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('UPDATE tempAction'..cc_playerGUID..' SET guid = '..cc_newCharacter..' WHERE guid = '..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('INSERT INTO character_action SELECT * FROM tempAction'..cc_playerGUID..';')
        local Data_SQL = CharDBQuery('DROP TABLE IF EXISTS tempAction'..cc_playerGUID..';')
        Data_SQL = nil

        coroutine.yield()
        --Copy items
        if not Config.keepStartingItems then
            local homeStone
            local Data_SQL = CharDBQuery('DELETE FROM item_instance WHERE owner_guid = '..cc_newCharacter..' AND itemEntry != 6948;')
            local Data_SQL = CharDBQuery('SELECT guid FROM item_instance WHERE owner_guid = '..cc_newCharacter..' AND itemEntry = 6948 LIMIT 1;')
            homeStone = Data_SQL:GetUInt32(0)
            local Data_SQL = CharDBQuery('DELETE FROM character_inventory WHERE guid = '..cc_newCharacter..' AND item != '..homeStone..';')
        end
        Data_SQL = nil

        local Data_SQL = CharDBQuery('SELECT item FROM character_inventory WHERE guid = '..cc_playerGUID..' AND bag = 0 AND slot <= 18 LIMIT 18;')
        local ItemCounter = 1
        local item_id = {}
        local item_amount = {}
        local i
        if Data_SQL ~= nil then
            repeat
                cc_oldItemGuids[ItemCounter] = Data_SQL:GetUInt32(0)
                local Data_SQL2 = CharDBQuery('SELECT itemEntry FROM item_instance WHERE guid = '..cc_oldItemGuids[ItemCounter]..' LIMIT 1;')
                item_id[ItemCounter] = Data_SQL2:GetUInt16(0)
                ItemCounter = ItemCounter + 1
            until not Data_SQL:NextRow()

            -- set amounts to 1 or nil
            for i = 1,18,1 do
                if item_id[i] ~= nil then
                    item_amount[i] = 1
                else
                    item_amount[i] = 1
                    item_id[i] = 38
                end
            end

            cc_newItemGuids[1], cc_newItemGuids[2], cc_newItemGuids[3], cc_newItemGuids[4], cc_newItemGuids[5], cc_newItemGuids[6], cc_newItemGuids[7], cc_newItemGuids[8], cc_newItemGuids[9], cc_newItemGuids[10], cc_newItemGuids[11], cc_newItemGuids[12] = SendMail("Copied items", "Hello "..targetName..Config.mailText, cc_newCharacter, 0, 61, 0, 0, 0, item_id[1], 1, item_id[2], 1, item_id[3], 1, item_id[4], 1, item_id[5], 1, item_id[6], 1, item_id[7], 1, item_id[8], 1, item_id[9], 1, item_id[10], 1, item_id[11], 1, item_id[12], 1)
            if cc_oldItemGuids[13] ~= nil then
                cc_newItemGuids[13], cc_newItemGuids[14], cc_newItemGuids[15], cc_newItemGuids[16], cc_newItemGuids[17], cc_newItemGuids[18] = SendMail("Copied items", "Hello "..targetName..Config.mailText, cc_newCharacter, 0, 61, 0, 0, 0, item_id[13], 1, item_id[14], 1, item_id[15], 1, item_id[16], 1, item_id[17], 1, item_id[18], 1)
            end
        end
        CreateLuaEvent(cc_fixItems, 3000) -- do it after 3 seconds
        cc_deleteTempTables(cc_playerGUID)

        cc_chatHandler:SendSysMessage("Character copy complete! The character "..targetName.." has been successfully copied.")
        cc_logPlayer(sourceName, sourceGuid, targetName, cc_newCharacter, player:GetLevel(), oldTickets - 1, oldTickets, CC_STATUS_SUCCESS, "Character copied")

        cc_resetVariables()

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
                cc_resetVariables()
                return false
            end
            if commandArray[2] == "help" then
                chatHandler:SendSysMessage("Syntax: .addcctickets $characterName $amount") -- Kept for Legacy / Compatibility
                cc_resetVariables()
                return false
            end
            if commandArray[2] == nil or commandArray[3] == nil then
                chatHandler:SendSysMessage("Syntax: .addcctickets $characterName $amount") -- Kept for Legacy / Compatibility
                cc_resetVariables()
                return false
            end

            if tonumber(commandArray[3]) > 1000 or tonumber(commandArray[3]) < 0 then
                chatHandler:SendSysMessage("Too large or negative amount chosen for .addcctickets: "..commandArray[3]..". Max allowed is +1000.")
                cc_resetVariables()
                return false
            end

            local normalisedCharacterName = cc_normalizeCharacterName(commandArray[2])
            Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;");
            if Data_SQL ~= nil then
                accountId = Data_SQL:GetUInt32(0)
            else
                chatHandler:SendSysMessage("Player name not found. Syntax: .addcctickets $characterName $amount")
                cc_resetVariables()
                return false
            end
            Data_SQL = nil
            local Data_SQL
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' LIMIT 1;');
            if Data_SQL  ~= nil then
                oldTickets = Data_SQL:GetUInt32(0)
            else
                oldTickets = 0
            end
            Data_SQL = nil

            if oldTickets >= 1000 or oldTickets < 0 then
                chatHandler:SendSysMessage("Too large total amount tickets: "..commandArray[3]..". Max allowed total is +1000. Current value: "..oldTickets)
                cc_resetVariables()
                return false
            end

            -- the `allow_copy_from_id` column is hardcoded to 0 for now. Only copies to the same account are possible.
            local Data_SQL
            Data_SQL = CharDBQuery('DELETE FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..';');
            Data_SQL = CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..accountId..', '..commandArray[3] + oldTickets..', 0);');
            Data_SQL = nil
            chatHandler:SendSysMessage("GM "..player:GetName().. " has sucessfully used the .addcctickets command, adding "..commandArray[3].." tickets to the account "..accountId.." which belongs to player "..normalisedCharacterName..".")
            cc_logAdmin(sourceName, sourceGuid, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + tonumber(commandArray[3]), CC_STATUS_SUCCESS, "GM .addcctickets")
            cc_resetVariables()
            return false
        else
            --player is nil, must be the console. no need to check gm rank and print to console only. not chat
            if commandArray[2] == "help" then
                chatHandler:SendSysMessage("Syntax: .addcctickets $characterName $amount") -- Kept for Legacy / Compatibility
                cc_resetVariables()
                return false
            end
            if commandArray[2] == nil or commandArray[3] == nil then
                chatHandler:SendSysMessage("Syntax: .addcctickets $characterName $amount") -- Kept for Legacy / Compatibility
                cc_resetVariables()
                return false
            end

            if tonumber(commandArray[3]) > 1000 or tonumber(commandArray[3]) < 0 then
                chatHandler:SendSysMessage("Too large or negative amount chosen for .addcctickets: "..commandArray[3]..". Max allowed is +1000.")
                cc_resetVariables()
                return false
            end

            local normalisedCharacterName = cc_normalizeCharacterName(commandArray[2])
            Data_SQL = CharDBQuery("SELECT `account` FROM `characters` WHERE `name` = "..cc_sqlQuote(normalisedCharacterName).." LIMIT 1;");
            if Data_SQL ~= nil then
                accountId = Data_SQL:GetUInt32(0)
            else
                chatHandler:SendSysMessage("Player name not found. Syntax: .addcctickets $characterName $amount")
                cc_resetVariables()
                return false
            end
            Data_SQL = nil
            local Data_SQL
            Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' LIMIT 1;');
            if Data_SQL  ~= nil then
                oldTickets = Data_SQL:GetUInt32(0)
            else
                oldTickets = 0
            end
            Data_SQL = nil

            if oldTickets >= 1000 or oldTickets < 0 then
                chatHandler:SendSysMessage("Too large total amount tickets: "..commandArray[3]..". Max allowed total is +1000. Current value: "..oldTickets)
                cc_resetVariables()
                return false
            end

            -- the `allow_copy_from_id` column is hardcoded to 0 for now. Only copies to the same account are possible.
            local Data_SQL
            Data_SQL = CharDBQuery('DELETE FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..';');
            Data_SQL = CharDBQuery('INSERT INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..accountId..', '..commandArray[3] + oldTickets..', 0);');
            Data_SQL = nil
            chatHandler:SendSysMessage("The console has sucessfully used the .addcctickets command, adding "..commandArray[3].." tickets to the account "..accountId.." which belongs to player "..normalisedCharacterName..".")
            cc_logAdmin("console", nil, normalisedCharacterName, nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + tonumber(commandArray[3]), CC_STATUS_SUCCESS, "Console .addcctickets")
            cc_resetVariables()
            return false
        end
    -- command for SOAP interface to send to worldserver console, granting tickets. Syntax: CCACCOUNTTICKETS $accountName $amount
    elseif commandArray[1] == "CCACCOUNTTICKETS" and commandArray[2] ~= nil and commandArray[3] ~= nil and player == nil then
        local Data_SQL
        Data_SQL = AuthDBQuery("SELECT `id` FROM `account` WHERE `username` = "..cc_sqlQuote(commandArray[2])..";")
        if Data_SQL == nil then
            PrintError("CCACCOUNTTICKETS to "..commandArray[2].." has failed.")
            cc_logAdmin("console", nil, commandArray[2], nil, nil, CC_ACTION_GM_ADD, nil, nil, CC_STATUS_FAILED, "CCACCOUNTTICKETS account not found")
            cc_resetVariables()
            return false
        else
            accountId = Data_SQL:GetUInt32(0)
        end

        if tonumber(commandArray[3]) > 1000 or tonumber(commandArray[3]) < 0 then
            chatHandler:SendSysMessage("Too large or negative amount chosen for .CCACCOUNTTICKETS: "..commandArray[3]..". Max allowed is +1000.")
            cc_resetVariables()
            return false
        end

        Data_SQL = CharDBQuery('SELECT `tickets` FROM `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` WHERE `account_id` = '..accountId..' LIMIT 1;');
        if Data_SQL  ~= nil then
            oldTickets = Data_SQL:GetUInt32(0)
        else
            oldTickets = 0
        end

        if oldTickets >= 1000 or oldTickets < 0 then
            chatHandler:SendSysMessage("Too large total amount of tickets: "..commandArray[3]..". Max allowed total is +1000. Current value: "..oldTickets)
            cc_logAdmin("console", nil, commandArray[2], nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets, CC_STATUS_FAILED, "CCACCOUNTTICKETS total exceeds max")
            cc_resetVariables()
            return false
        end

        CharDBExecute('REPLACE INTO `'..Config.customDbName..'`.`'..cc_carboncopyTable..'` VALUES ('..accountId..', '..commandArray[3] + oldTickets..', 0) ;')
        cc_logAdmin("console", nil, commandArray[2], nil, nil, CC_ACTION_GM_ADD, oldTickets, oldTickets + tonumber(commandArray[3]), CC_STATUS_SUCCESS, "CCACCOUNTTICKETS success")
        cc_resetVariables()
        return false
    elseif player ~= nil then
        -- CCACCOUNTTICKETS is SOAP / console only: stay silent for players, like .addcctickets
        return false
    else
        chatHandler:SendSysMessage("Syntax: CCACCOUNTTICKETS $accountName $amount")
        return false
    end
end

function cc_fixItems()
    local n
    local Data_SQL
    for n,_ in ipairs(cc_oldItemGuids) do
        QueryString = 'UPDATE `item_instance` AS t1 '
        QueryString = QueryString..'INNER JOIN `item_instance` AS t2 ON t2.guid = '..cc_oldItemGuids[n]..' '
        QueryString = QueryString..'SET t1.owner_guid = '..cc_newCharacter..', t1.creatorGuid = t2.creatorGuid, '
        QueryString = QueryString..'t1.duration = t2.duration, t1.charges = t2.charges, t1.flags = 1, '
        QueryString = QueryString..'t1.enchantments = t2.enchantments, t1.randomPropertyId = t2.randomPropertyId '
        QueryString = QueryString..'WHERE t1.guid = '..cc_newItemGuids[n]..';'
        Data_SQL = CharDBQuery(QueryString);
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
                local name        = sets_SQL:GetString(1):gsub("'", "''")
                local iconname    = sets_SQL:GetString(2):gsub("'", "''")
                local ignore_mask = sets_SQL:GetUInt32(3)
                local items = {}
                for i = 0, 18 do
                    local oldGuid = sets_SQL:GetUInt32(4 + i)
                    items[i] = guidMap[oldGuid] or 0
                end
                CharDBQuery('INSERT INTO `character_equipmentsets` (`guid`, `setindex`, `name`, `iconname`, `ignore_mask`, `item0`, `item1`, `item2`, `item3`, `item4`, `item5`, `item6`, `item7`, `item8`, `item9`, `item10`, `item11`, `item12`, `item13`, `item14`, `item15`, `item16`, `item17`, `item18`) VALUES ('
                    ..cc_newCharacter..', '..setindex..', \''..name..'\',' ..' \''..iconname..'\', '..ignore_mask..', '
                    ..items[0]..', '..items[1]..', '..items[2]..', '..items[3]..', '..items[4]..', '
                    ..items[5]..', '..items[6]..', '..items[7]..', '..items[8]..', '..items[9]..', '
                    ..items[10]..', '..items[11]..', '..items[12]..', '..items[13]..', '..items[14]..', '
                    ..items[15]..', '..items[16]..', '..items[17]..', '..items[18]..');')
            until not sets_SQL:NextRow()
        end
    end

    local copyingPlayer = GetPlayerByGUID(cc_playerGUID)
    if copyingPlayer ~= nil then
        copyingPlayer:SendBroadcastMessage("Character copy done. You can log out now.")
    end
    PrintInfo("2) Item enchants/gems copied for new character with GUID "..cc_newCharacter);
    cc_newCharacter = 0
    cc_newCharacterName = nil
    cc_copyTicketsBefore = nil
    cc_copyTicketsAfter = nil
    cc_oldItemGuids = {}
    cc_newItemGuids = {}
    cc_scriptIsBusy = 0
    cc_playerGUID = nil
end

function cc_resetVariables()
    Data_SQL = nil
    Data_SQL2 = nil
    ItemCounter = nil
    targetName = nil
    QueryString = nil
    cc_playerPetId = nil
    cc_targetPetId = nil
    item_id = nil
    homeStone = nil
    cc_playerString = nil
    cc_cinematic = nil
    commandArray = nil
    availableTickets = nil
    newItemGuid = nil
end

function cc_deleteTempTables(cc_GUID)
    CharDBQuery('DROP TABLE IF EXISTS tempQuest'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempPet'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempPet_spell'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempReputation'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempSkills'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempSpell'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempTalent'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempGlyphs'..cc_GUID..';')
    CharDBQuery('DROP TABLE IF EXISTS tempAction'..cc_GUID..';')
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
    coroutine.resume(cc_subRoutine)
end

local PLAYER_EVENT_ON_COMMAND = 42
local PLAYER_EVENT_ON_LOGOUT = 4

-- If the player who initiated a copy disconnects mid-copy, release the busy lock.
-- The coroutine will still finish its DB work, but the lock would never reset otherwise.
local function cc_OnPlayerLogout(event, player)
    if cc_scriptIsBusy ~= 0 and cc_playerGUID ~= nil then
        local guid = tonumber(tostring(player:GetGUID()))
        if guid == cc_playerGUID then
            PrintInfo("CarbonCopy: Source player disconnected mid-copy (GUID "..cc_playerGUID.."). Releasing busy lock.")
            cc_logPlayer(
                player:GetName(), guid,
                cc_newCharacterName, cc_newCharacter ~= 0 and cc_newCharacter or nil,
                player:GetLevel(),
                cc_copyTicketsBefore, cc_copyTicketsAfter,
                CC_STATUS_FAILED, "Source player disconnected mid-copy"
            )
            cc_scriptIsBusy = 0
            cc_playerGUID = nil
            cc_newCharacterName = nil
            cc_copyTicketsBefore = nil
            cc_copyTicketsAfter = nil
        end
    end
end

-- function to be called when the command hook fires
RegisterPlayerEvent(PLAYER_EVENT_ON_COMMAND, cc_CopyCharacter)
RegisterPlayerEvent(PLAYER_EVENT_ON_LOGOUT, cc_OnPlayerLogout)
