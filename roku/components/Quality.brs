sub initQuality()
    m.qualityPanel = m.top.findNode("qualityPanel")
    m.qualityList = m.top.findNode("qualityList")
    m.qualityStatus = m.top.findNode("qualityStatus")
    m.qualityList.observeField("itemSelected", "onQualitySelected")
    m.qualityOpen = false
    m.qualityChanging = false
    m.qualityResumePaused = false
    m.qualityChoices = []
    m.qualityBackHeld = false
    m.qualityOptionsHeld = false
    m.timeJumpOpen = false
end sub

sub openPlaybackOptions()
    if not m.isVod
        openQuality()
        return
    end if
    if m.busy or m.qualityChanging then return
    if m.seekKey <> "" then finishVodSeek(false)
    m.qualityOpen = true
    m.qualityPanel.visible = true
    m.qualityChoices = ["jump", "quality_menu"]
    content = CreateObject("roSGNode", "ContentNode")
    for each title in ["Jump to time", "Video quality", "Close"]
        item = content.createChild("ContentNode")
        item.title = title
    end for
    m.qualityList.content = content
    m.qualityList.jumpToItem = 0
    m.qualityStatus.text = "Position: " + vodTimeText(m.video.position)
    m.qualityList.setFocus(true)
end sub

sub openQuality()
    if m.busy or m.qualityChanging then return
    if m.isVod and m.seekKey <> "" then finishVodSeek(false)
    m.qualityOpen = true
    m.qualityPanel.visible = true
    m.qualityChoices = []
    m.qualityList.content = CreateObject("roSGNode", "ContentNode")
    m.qualityStatus.text = "Loading available qualities..."
    m.qualityList.setFocus(true)
    m.qualityTargetJob = m.jobId
    requestQualities()
end sub

sub requestQualities()
    if not m.qualityOpen or m.busy then return
    callApi("qualities", "/api/player/qualities?job_id=" + m.qualityTargetJob.EncodeUriComponent(), "GET", {})
end sub

function qualityLabel(value as string) as string
    if value = "best" then return "Highest available"
    return value
end function

sub receiveQualities(d as object)
    if not m.qualityOpen then return
    if d.state = "starting"
        schedule("qualities", 1)
        return
    end if
    m.timerAction = ""
    m.qualityChoices = d.qualities
    content = CreateObject("roSGNode", "ContentNode")
    for each quality in m.qualityChoices
        item = content.createChild("ContentNode")
        item.title = qualityLabel(quality)
        if quality = d.quality then item.title += " (current)"
    end for
    item = content.createChild("ContentNode")
    item.title = "Close"
    m.qualityList.content = content
    m.qualityList.jumpToItem = 0
    m.qualityList.setFocus(true)
    m.qualityStatus.text = "Remembered for your account. Switching briefly buffers."
end sub

sub onQualitySelected()
    if m.busy or not m.qualityOpen then return
    index = m.qualityList.itemSelected
    if index < 0 then return
    if index >= m.qualityChoices.count()
        closeQuality()
        return
    end if
    if m.qualityChoices[index] = "jump"
        openTimeJump()
        return
    else if m.qualityChoices[index] = "quality_menu"
        openQuality()
        return
    end if
    if m.isVod and (not m.vodHasPosition or m.seekPending)
        m.qualityStatus.text = "Wait for the playback position, then try again."
        return
    end if
    body = playbackProgressBody()
    body.quality = m.qualityChoices[index]
    m.qualityResumePaused = m.vodPaused
    m.qualityChanging = true
    m.vodPaused = true
    m.video.control = "pause"
    m.qualityStatus.text = "Switching quality..."
    callApi("quality", "/api/player/quality", "POST", body)
end sub

sub beginQualityPlayback(d as object)
    closeQuality()
    m.heartbeat.control = "stop"
    m.video.visible = false
    m.video.control = "stop"
    m.jobId = d.id
    if d.state = "ready"
        startVideo(d)
    else if d.state = "starting"
        m.status.text = "Switching quality..."
        schedule("player", 2)
    else
        m.qualityChanging = false
        m.qualityResumePaused = false
        restoreFocus()
        m.status.text = "Could not switch quality. Open the video again."
    end if
end sub

sub qualityError(message as string)
    if m.qualityChanging
        m.vodPaused = m.qualityResumePaused
        m.qualityResumePaused = false
        m.qualityChanging = false
        if not m.vodPaused then m.video.control = "resume"
    end if
    if m.qualityOpen then m.qualityStatus.text = message
end sub

sub closeQuality()
    m.qualityOpen = false
    m.qualityPanel.visible = false
    if m.timerAction = "qualities"
        m.timer.control = "stop"
        m.timerAction = ""
    end if
    if m.video.visible then m.vodInput.setFocus(true)
end sub

function handleQualityKey(key as string, press as boolean) as boolean
    if key = "back" and m.qualityBackHeld
        if not press then m.qualityBackHeld = false
        return true
    end if
    if key = "options" and (m.video.visible or m.qualityOpen)
        if not press
            m.qualityOptionsHeld = false
            return m.video.visible
        end if
        if m.qualityOptionsHeld then return true
        m.qualityOptionsHeld = true
    end if
    if m.qualityOpen
        if key = "back" or key = "options"
            if key = "back" and press then m.qualityBackHeld = true
            if press then closeQuality()
            return true
        end if
        return false
    end if
    if not m.video.visible then return false
    if key = "options"
        if press then openPlaybackOptions()
        return true
    end if
    if m.qualityChanging then return key <> "back"
    if not m.isVod and (key = "OK" or key = "play" or key = "playonly" or key = "pause")
        if not press
            m.transportKey = ""
            return true
        end if
        if m.transportKey = key then return true
        m.transportKey = key
        if key = "pause"
            m.vodPaused = true
        else if key = "playonly"
            m.vodPaused = false
        else
            m.vodPaused = not m.vodPaused
        end if
        if m.vodPaused
            m.video.control = "pause"
        else
            m.video.control = "resume"
        end if
        return true
    end if
    return false
end function
