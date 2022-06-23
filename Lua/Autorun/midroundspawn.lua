-- MidRoundSpawn v4 - offers newly joined players the option to spawn mid-round
-- by MassCraxx

if CLIENT then return end

-- CONFIG
local CheckDelaySeconds = 10
local SpawnDelaySeconds = 0
local ForceSpectatorSpawn = false


local CheckTime = -1
local HasBeenSpawned = {}
local NewPlayers = {}

MidRoundSpawn = {}
MidRoundSpawn.Log = function (message)
    Game.Log("[MidRoundSpawn] " .. message, 6)
end

MidRoundSpawn.SpawnClientCharacterOnSub = function(client)
    if not Game.RoundStarted or not client.InGame then return false end 

    local spawned = MidRoundSpawn.TryCreateClientCharacter(client)
    HasBeenSpawned[client.SteamID] = spawned

    return spawned
end

-- TryCreateClientCharacter inspied by Oiltanker
MidRoundSpawn.TryCreateClientCharacter = function(client)
    local session = Game.GameSession
    local crewManager = session.CrewManager

    -- fix client char info
    if client.CharacterInfo == nil then client.CharacterInfo = CharacterInfo.__new('human', client.Name) end

    local jobPreference = client.JobPreferences[1]
    if jobPreference ~= nil then
        client.AssignedJob = jobPreference
        client.CharacterInfo.Job = Job.__new(jobPreference.Prefab, 0, jobPreference.Variant);
    end

    crewManager.AddCharacterInfo(client.CharacterInfo)

    local spawnWayPoints = WayPoint.SelectCrewSpawnPoints({client.CharacterInfo}, Submarine.MainSub)
    local randomIndex = Random.Range(1, #spawnWayPoints)
    local waypoint = spawnWayPoints[randomIndex]

    -- find waypoint the hard way
    if waypoint == nil then
        for i,wp in pairs(WayPoint.WayPointList) do
            if
                wp.AssignedJob ~= nil and
                wp.SpawnType == SpawnType.Human and
                wp.Submarine == Submarine.MainSub and
                wp.CurrentHull ~= nil
            then
                if client.CharacterInfo.Job.Prefab == wp.AssignedJob then
                    waypoint = wp
                    break
                end
            end
        end
    end

    -- none found, go random
    if waypoint == nil then 
        MidRoundSpawn.Log("WARN: No valid job waypoint found for " .. tostring(client.CharacterInfo.Job.Prefab.Identifier) .. " - using random")
        waypoint = WayPoint.GetRandom(SpawnType.Human, nil, Submarine.MainSub)
    end

    if waypoint == nil then 
        MidRoundSpawn.Log("ERROR: Could not spawn player - no valid waypoint found")
        return false 
    end

    MidRoundSpawn.Log("Spawning new client " .. client.Name .. " in ".. tostring(SpawnDelaySeconds) .. " seconds")

    Timer.Wait(function () 
        -- spawn character
        local char = Character.Create(client.CharacterInfo, waypoint.WorldPosition, client.CharacterInfo.Name, 0, true, true);
        char.TeamID = CharacterTeamType.Team1;
        crewManager.AddCharacter(char)

        client.SetClientCharacter(char);
        --mcm_client_manager:set(client, char)
        
        char.GiveJobItems(waypoint);
    end, SpawnDelaySeconds * 1000)

    return true
end

MidRoundSpawn.CreateDialog = function()
    local c = {}

    local currentPromptID = 0
    local promptIDToCallback = {}

    local function SendEventMessage(msg, options, id, eventSprite, client)
        local message = Networking.Start()
        message.Write(Byte(18)) -- net header
        message.Write(Byte(0)) -- conversation

        message.Write(UShort(id)) -- ushort identifier 0
        message.Write(eventSprite) -- event sprite
        message.Write(UShort(2))
        message.Write(false) -- continue conversation

        message.Write(Byte(2))
        message.Write(msg)
        message.Write(false)
        message.Write(Byte(#options))
        for key, value in pairs(options) do
            message.Write(value)
        end
        message.Write(Byte(#options))
        for i = 0, #options - 1, 1 do
            message.Write(Byte(i))
        end

        Networking.Send(message, client.Connection, DeliveryMethod.Reliable)
    end


    Hook.Add("netMessageReceived", "promptResponse", function (msg, header, client)
        if header == ClientPacketHeader.EVENTMANAGER_RESPONSE then 
            local id = msg.ReadUInt16()
            local option = msg.ReadByte()

            if promptIDToCallback[id] ~= nil then
                promptIDToCallback[id](option, client)
            end
        end
    end)

    c.Prompt = function (message, options, client, callback, eventSprite)
        currentPromptID = currentPromptID + 1

        promptIDToCallback[currentPromptID] = callback
        SendEventMessage(message, options, currentPromptID, eventSprite, client)
    end

    return c
end

MidRoundSpawn.ShowSpawnDialog = function(client)
    local dialog = MidRoundSpawn.CreateDialog()
    dialog.Prompt("Do you want to spawn instantly or wait for the next respawn?\n", {"> Spawn", "> Wait"}, client, function(option, client) 
        if option == 0 then
            MidRoundSpawn.SpawnClientCharacterOnSub(client)
        end
    end)
end

Hook.Add("roundStart", "MidRoundSpawn.roundStart", function ()
    -- Reset tables
    HasBeenSpawned = {}
    NewPlayers = {}

    -- Flag all lobby players as spawned
    for key, client in pairs(Client.ClientList) do
        if not client.SpectateOnly then
            HasBeenSpawned[client.SteamID] = true
        else
            MidRoundSpawn.Log(client.Name .. " is spectating.")
        end
    end
end)

Hook.Add("clientConnected", "MidRoundSpawn.clientConnected", function (newClient)
    -- client connects, round has started and client has not been considered for spawning yet
    if not Game.RoundStarted or HasBeenSpawned[newClient.SteamID] then return end

    if newClient.InGame then
        -- if client for some reason is already InGame (lobby skip?) spawn
        MidRoundSpawn.SpawnClientCharacterOnSub(newClient)
    else
        -- else store for later spawn 
        MidRoundSpawn.Log("Adding new player to spawn list: " .. newClient.Name)
        table.insert(NewPlayers, newClient)

        -- inform player about his luck
        Game.SendDirectChatMessage("", ">> MidRoundSpawn active! <<\nThe round has already started, but you can spawn instantly!", nil, ChatMessageType.Private, newClient)
    end
end)

Hook.Add("think", "MidRoundSpawn.think", function ()
    if Game.RoundStarted and CheckTime and Timer.GetTime() > CheckTime then
        CheckTime = Timer.GetTime() + CheckDelaySeconds
        
        -- check all NewPlayers and if not spawned already and inGame spawn
        for i = #NewPlayers, 1, -1 do
            local newClient = NewPlayers[i]
            
            -- if client still valid and not spawned yet, no spectator and has an active connection
            if newClient and not HasBeenSpawned[newClient.SteamID] and (ForceSpectatorSpawn or not newClient.SpectateOnly) and newClient.Connection and newClient.Connection.Status == 1 then
                -- wait for client to be ingame, then cpasn
                if newClient.InGame then
                    MidRoundSpawn.ShowSpawnDialog(newClient)
                    table.remove(NewPlayers, i)
                --else
                    --MidRoundSpawn.Log(newClient.Name .. " waiting in lobby...")
                end
            else
                if (not ForceSpectatorSpawn and newClient.SpectateOnly) then
                    MidRoundSpawn.Log("Removing spectator from spawn list: " .. newClient.Name)
                else
                    MidRoundSpawn.Log("Removing invalid player from spawn list: " .. newClient.Name)
                end
                table.remove(NewPlayers, i)
            end
        end
    end
end)

-- Commands hook
Hook.Add("chatMessage", "MidRoundSpawn.ChatMessage", function (message, client)

    if message == "!midroundspawn" then
        if not HasBeenSpawned[client.SteamID] or client.HasPermission(ClientPermissions.All) then
            MidRoundSpawn.ShowSpawnDialog(client)
        else
            Game.SendDirectChatMessage("", "You spawned already.", nil, ChatMessageType.Error, client)
        end
        return true
    end
end)