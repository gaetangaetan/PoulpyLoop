-- Début de votre script principal (ex: dmx_control.lua)
local mrArtNet = {
    IP = "192.168.0.14",      -- IP du contrôleur DMX
    PORT = 6454,              -- Port Art-Net standard
    UNIVERSE = 0,             -- Univers DMX par défaut
    socket = nil,             -- Socket UDP
    dmx = {},                 -- Buffer DMX (512 canaux)
    sequence = 0              -- Compteur de séquence Art-Net
}

-- Initialisation du buffer DMX
for i = 1, 512 do mrArtNet.dmx[i] = 0 end

-- Fonctions encapsulées (évite les collisions de noms)
function mrArtNet:init()
    if not reaper.Socket_Create then 
        reaper.ShowMessageBox("Extension Sockets non disponible", "Erreur", 0)
        return false 
    end
    self.socket = reaper.Socket_Create("AF_INET", "SOCK_DGRAM")
    return self.socket ~= nil
end

function mrArtNet:send()
    if not self.socket then return false end
    
    self.sequence = (self.sequence + 1) % 256
    local header = string.pack(
        "zHHBBBBH", 
        "Art-Net", 0x5000, 0x000e, 
        self.sequence, self.UNIVERSE % 256, 0x02, 0x0200
    )
    
    local data = header .. string.char(unpack(self.dmx))
    return reaper.Socket_SendTo(self.socket, self.IP, self.PORT, data)
end

function mrArtNet:setChannel(ch, value)
    if ch >= 1 and ch <= 512 then
        self.dmx[ch] = math.floor(math.min(255, math.max(0, value)))
    end
end

function mrArtNet:cleanup()
    if self.socket then
        reaper.Socket_Close(self.socket)
        self.socket = nil
    end
end

-- ================================================
-- VOTRE SCRIPT PRINCIPAL COMMENCE ICI
-- ================================================
local function main()
    if not mrArtNet:init() then return end
    
    -- Exemple : Fade progressif du canal 1
    local t = reaper.time_precise() % 2  -- Cycle de 2 secondes
    mrArtNet:setChannel(1, t * 255)     -- 0 → 255 linéaire
    
    if not mrArtNet:send() then
        reaper.ShowConsoleMsg("Erreur envoi DMX\n")
    end
    
    reaper.defer(main)  -- Boucle à ~30Hz
end

-- Gestion propre de la fermeture
reaper.atexit(mrArtNet.cleanup)
main()  -- Démarrage
