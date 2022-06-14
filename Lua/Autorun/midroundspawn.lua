-- MidRoundSpawn v1 - spawns new players that have not spawned at least once while the round has already started
-- by MassCraxx

if CLIENT then return end

-- CONFIG
local checkDelay = 10
local checkTime = -1

local HasBeenSpawned = {}
local NewPlayers = {}

MidRoundSpawn = {}
MidRoundSpawn.Log = function (message)
    Game.Log("[MidRoundSpawn] " .. message, 6)
end

MidRoundSpawn.SpawnClientCharacterOnSub = function(client)
    if not Game.RoundStarted or not client.InGame then return false end 
    MidRoundSpawn.Log("Spawning new client " .. client.Name)

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

    -- spawn character
    local char = Character.Create(client.CharacterInfo, waypoint.WorldPosition, client.CharacterInfo.Name, 0, true, true);
    char.TeamID = CharacterTeamType.Team1;
    crewManager.AddCharacter(char)

    client.SetClientCharacter(char);
    --mcm_client_manager:set(client, char)
    
    char.GiveJobItems(waypoint);

    return true
end

Hook.Add("roundStart", "MidRoundSpawn.roundStart", function ()
    -- Reset tables
    HasBeenSpawned = {}
    NewPlayers = {}

    -- Flag all lobby players as spawned
    for key, client in pairs(Client.ClientList) do
        HasBeenSpawned[client.SteamID] = true
    end
end)

Hook.Add("clientConnected", "MidRoundSpawn.clientConnected", function (newClient)
    -- ignore if no round started, client is spectator or has been spawned in this round already
    if not Game.RoundStarted or newClient.Spectating or HasBeenSpawned[newClient.SteamID] then return end

    -- client connects, round has started and client has not been considered for spawning yet
    if newClient.InGame then
        -- if client for some reason is already InGame (lobby skip?) spawn
        MidRoundSpawn.SpawnClientCharacterOnSub(newClient)
    else
        -- else store for later spawn 
        MidRoundSpawn.Log("Adding new player to spawn list: " .. newClient.Name)
        table.insert(NewPlayers, newClient)
    end
end)

Hook.Add("think", "MidRoundSpawn.think", function ()
    if Game.RoundStarted and checkTime and Timer.GetTime() > checkTime then
        checkTime = Timer.GetTime() + checkDelay
        
        -- check all NewPlayers and if not spawned already and inGame spawn
        for i = #NewPlayers, 1, -1 do
            local newClient = NewPlayers[i]
            MidRoundSpawn.Log(newClient.Name .. " waiting to be spawned...")

            if newClient and newClient.Connection and newClient.Connection.Status == 1 then
                if not HasBeenSpawned[newClient.SteamID] and newClient.InGame then
                    if MidRoundSpawn.SpawnClientCharacterOnSub(newClient) then
                        -- if client successfully spawned, remove
                        table.remove(NewPlayers, i)
                    end
                end
            else
                -- if client disconnected, remove
                table.remove(NewPlayers, i)
            end
        end
    end
end)

-- Commands hook
Hook.Add("chatMessage", "MidRoundSpawn.ChatMessage", function (message, client)
    if not client.HasPermission(ClientPermissions.ConsoleCommands) then return end

    if message == "!midroundspawn" then
        MidRoundSpawn.SpawnClientCharacterOnSub(client)
        return true
    end
end)