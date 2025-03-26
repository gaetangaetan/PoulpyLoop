local mrArtNet = {
    IP = "192.168.0.14",
    PORT = 6454,
    UNIVERSE = 0,
    socket = nil,
    dmx = {}
}

-- Initialise le buffer DMX (512 canaux)
for i = 1, 512 do
    mrArtNet.dmx[i] = 0
end

-- Ouvre le socket UDP
function mrArtNet:init()
    self.socket = reaper.Socket_Create("AF_INET", "SOCK_DGRAM")
    if not self.socket then 
        reaper.ShowMessageBox("Erreur création socket", "ArtNet Error", 0)
        return false
    end
    return true
end

-- Envoi d'une trame Art-Net (version simplifiée)
function mrArtNet:send()
    if not self.socket then return false end

    local header = "Art-Net\0" .. 
                  string.char(0x00, 0x50) ..  -- OpCode (ArtDmx)
                  string.char(0x00, 0x0e) ..  -- Protocole v14
                  string.char(self.UNIVERSE) .. 
                  string.char(0x02)  -- Sequence (désactivé)

    -- Convertit le tableau DMX en binaire
    local data = header .. table.concat({
        string.char(0x00, 0x00),  -- Physical + SubUni
        string.char(0x00, 0x02)    -- Length (512 canaux)
    }) .. string.char(unpack(self.dmx))

    return reaper.Socket_SendTo(self.socket, self.IP, self.PORT, data)
end

-- Met à jour un canal DMX
function mrArtNet:setChannel(ch, value)
    if ch >= 1 and ch <= 512 then
        self.dmx[ch] = math.min(255, math.max(0, value))
    end
end

-- Nettoyage
function mrArtNet:cleanup()
    if self.socket then
        reaper.Socket_Close(self.socket)
        self.socket = nil
    end
end

return mrArtNet