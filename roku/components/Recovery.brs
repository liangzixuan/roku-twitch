sub initRecovery()
    m.stallTimer = m.top.findNode("stallTimer")
    m.stableTimer = m.top.findNode("stableTimer")
    m.stallTimer.observeField("fire", "onPlaybackStalled")
    m.stableTimer.observeField("fire", "onPlaybackStable")
    clearRecovery()
end sub

sub clearRecovery()
    m.recovering = false
    m.recoveryToken = ""
    m.recoveryRetries = 0
    m.recoverySequence = 0
    m.recoveryPosition = 0.0
    m.recoveryPaused = false
    m.stallTimer.control = "stop"
    m.stableTimer.control = "stop"
end sub

sub rememberRecovery(d as object)
    if d.recovery_id = invalid or d.recovery_id = "" then return
    if d.recovery_id <> m.recoveryToken
        clearRecovery()
        m.recoveryToken = d.recovery_id
    end if
    if d.id <> invalid then m.jobId = d.id
    if d.kind <> invalid then m.isVod = d.kind = "vod"
    if d.play_start <> invalid then m.recoveryPosition = d.play_start * 1.0
end sub

function terminalRecoveryError(code as dynamic) as boolean
    if code = invalid then return false
    return code = 400 or code = 401 or code = 403 or code = 404 or code = 409 or code = 410 or code = 422
end function

sub beginRecovery(message as string)
    if m.recoveryToken = ""
        stopPlayback(message)
        return
    end if
    if not m.recovering
        m.recoveryPaused = m.vodPaused
        if m.qualityChanging then m.recoveryPaused = m.qualityResumePaused
        if m.isVod and m.vodHasPosition then m.recoveryPosition = m.lastVodPosition
        m.recovering = true
        m.video.visible = false
        m.video.control = "stop"
        closeQuality()
        closeTimeJump()
        m.qualityChanging = false
        m.heartbeat.control = "stop"
        m.stallTimer.control = "stop"
        m.stableTimer.control = "stop"
        m.seekTimer.control = "stop"
        m.hudTimer.control = "stop"
        m.vodHud.visible = false
        m.vodInput.setFocus(true)
    end if
    if m.recoveryRetries >= 3
        stopPlayback("Could not restore playback after 3 attempts. Open the video to try again.")
        return
    end if
    delays = [2, 5, 10]
    m.status.text = "Reconnecting (" + (m.recoveryRetries + 1).toStr() + "/3)... Back: Cancel"
    schedule("recover", delays[m.recoveryRetries])
end sub

sub requestRecovery()
    if not m.recovering then return
    m.recoveryRetries++
    m.recoverySequence++
    body = {recovery_id: m.recoveryToken, attempt: m.recoverySequence}
    if m.isVod then body.position = m.recoveryPosition
    callApi("recover", "/api/player/recover", "POST", body)
end sub

function handleRecoveryResult(result as object) as boolean
    if m.recovering and m.action <> "recover" and m.action <> "player" and m.action <> "stop" then return true
    if m.action = "recover" or (m.action = "player" and m.recovering)
        if not result.ok
            if terminalRecoveryError(result.status_code)
                stopPlayback(result.message)
            else
                beginRecovery(result.message)
            end if
        else
            d = result.data
            rememberRecovery(d)
            if d.state = "ready"
                m.qualityResumePaused = m.recoveryPaused
                m.recovering = false
                startVideo(d)
            else if d.state = "starting"
                schedule("player", 2)
            else
                beginRecovery("Playback could not restart.")
            end if
        end if
        return true
    end if
    if m.action = "heartbeat" and not result.ok
        if terminalRecoveryError(result.status_code) and result.status_code <> 409
            stopPlayback(result.message)
        else
            beginRecovery(result.message)
        end if
        return true
    end if
    return false
end function

sub onPlaybackStalled()
    if m.video.visible and not m.qualityChanging and not m.vodPaused and m.seekKey = "" and m.video.state = "buffering" then beginRecovery("Playback stalled.")
end sub

sub onPlaybackStable()
    if m.video.visible and m.video.state = "playing" and not m.recovering and not m.qualityChanging and not m.vodPaused then m.recoveryRetries = 0
end sub

sub watchPlaybackState()
    m.stallTimer.control = "stop"
    m.stableTimer.control = "stop"
    if m.video.state = "buffering" and not m.vodPaused and m.seekKey = "" then m.stallTimer.control = "start"
    if m.video.state = "playing" and not m.vodPaused then m.stableTimer.control = "start"
end sub
