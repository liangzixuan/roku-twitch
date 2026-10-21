sub initVodControls()
    m.vodHud = m.top.findNode("vodHud")
    m.vodTime = m.top.findNode("vodTime")
    m.vodInput = m.top.findNode("vodInput")
    m.playIcon = m.top.findNode("playIcon")
    m.pauseIcon = m.top.findNode("pauseIcon")
    m.vodFill = m.top.findNode("vodFill")
    m.seekTimer = m.top.findNode("seekTimer")
    m.hudTimer = m.top.findNode("hudTimer")
    m.seekClock = CreateObject("roTimespan")
    m.seekTimer.observeField("fire", "onSeekTick")
    m.hudTimer.observeField("fire", "hideVodHud")
    m.video.observeField("position", "onVodPosition")
    resetVodControls()
end sub

sub resetVodControls()
    m.seekTimer.control = "stop"
    m.hudTimer.control = "stop"
    m.vodHud.visible = false
    m.isVod = false
    m.seekKey = ""
    m.seekTarget = 0.0
    m.seekPending = false
    m.vodPaused = false
    m.transportKey = ""
    m.backHeld = false
    m.hudDismissed = false
    m.vodHasPosition = false
    m.lastVodPosition = 0.0
end sub

function vodDuration() as float
    duration = m.video.duration
    if duration <= 0 then duration = m.video.content.length
    return duration * 1.0
end function

function seekStep(heldMs as integer) as integer
    if heldMs >= 10000 then return 300
    if heldMs >= 5000 then return 60
    if heldMs >= 2000 then return 30
    return 10
end function

function clampSeek(target as float, duration as float) as float
    limit = duration - 2
    if limit < 0 then limit = 0.0
    if target < 0 then return 0.0
    if target > limit then return limit
    return target
end function

function vodTimeText(seconds as float) as string
    whole = Int(seconds)
    if whole < 0 then whole = 0
    hours = Int(whole / 3600)
    minutes = Int((whole mod 3600) / 60)
    secs = whole mod 60
    minuteText = minutes.toStr()
    secondText = secs.toStr()
    if minutes < 10 then minuteText = "0" + minuteText
    if secs < 10 then secondText = "0" + secondText
    return hours.toStr() + ":" + minuteText + ":" + secondText
end function

sub showVodHud()
    duration = vodDuration()
    position = m.video.position
    if position = invalid then position = 0
    if m.seekKey <> "" or m.seekPending then position = m.seekTarget
    m.vodTime.text = vodTimeText(position) + " / " + vodTimeText(duration)
    if duration > 0
        m.vodFill.width = 1080 * clampSeek(position, duration) / duration
    else
        m.vodFill.width = 0
    end if
    m.playIcon.visible = m.vodPaused or m.seekKey <> ""
    m.pauseIcon.visible = not m.playIcon.visible
    m.vodHud.visible = true
end sub

sub hideVodHud()
    if m.seekKey = "" and not m.vodPaused and m.video.state <> "buffering"
        m.vodHud.visible = false
    end if
end sub

sub onVodPosition()
    if not m.isVod or not m.video.visible then return
    if m.seekKey = "" and m.seekPending
        if Abs(m.video.position - m.seekTarget) < 15 then m.seekPending = false
    end if
    if not m.seekPending and m.seekKey = "" and (m.video.state = "playing" or m.video.state = "paused")
        m.lastVodPosition = m.video.position
        m.vodHasPosition = true
    end if
    if m.vodHud.visible then showVodHud()
end sub

sub beginVodSeek(key as string, direction as integer)
    if m.seekKey = key then return
    if vodDuration() <= 0 then return
    if m.video.state <> "playing" and m.video.state <> "paused" and not m.seekPending and m.seekKey = "" then return
    if m.seekKey = ""
        if not m.seekPending then m.seekTarget = m.video.position
        if m.seekTarget = invalid then m.seekTarget = 0
        m.seekOrigin = m.seekTarget
        m.video.control = "pause"
    end if
    m.hudDismissed = false
    m.hudTimer.control = "stop"
    m.seekKey = key
    m.seekDirection = direction
    m.seekClock.Mark()
    advanceVodSeek(0)
    m.seekTimer.control = "start"
end sub

sub advanceVodSeek(heldMs as integer)
    m.seekTarget = clampSeek(m.seekTarget + m.seekDirection * seekStep(heldMs), vodDuration())
    showVodHud()
end sub

sub onSeekTick()
    if m.seekKey = "" then return
    if not m.top.isInFocusChain()
        finishVodSeek(false)
        return
    end if
    if m.qualityOpen <> true and m.timeJumpOpen <> true then m.vodInput.setFocus(true)
    advanceVodSeek(m.seekClock.TotalMilliseconds())
end sub

sub finishVodSeek(commit as boolean)
    if m.seekKey = "" then return
    m.seekTimer.control = "stop"
    m.seekKey = ""
    if commit
        m.seekPending = true
        m.video.autoplayAfterSeek = not m.vodPaused
        m.video.seek = m.seekTarget
    else
        m.seekTarget = m.seekOrigin
        if not m.vodPaused then m.video.control = "resume"
    end if
    showVodHud()
    m.hudTimer.control = "start"
end sub

function handleVodKey(key as string, press as boolean) as boolean
    if not m.isVod or not m.video.visible then return false
    if key = "left" or key = "right" or key = "rewind" or key = "fastforward"
        if press
            direction = 1
            if key = "left" or key = "rewind" then direction = -1
            beginVodSeek(key, direction)
        else if m.seekKey = key
            finishVodSeek(true)
        end if
        return true
    end if
    if key = "back"
        if not press
            m.backHeld = false
            return true
        end if
        if m.backHeld then return true
        if m.seekKey <> "" or m.vodHud.visible
            m.backHeld = true
            if m.seekKey <> "" then finishVodSeek(false)
            m.hudDismissed = true
            m.hudTimer.control = "stop"
            m.vodHud.visible = false
            return true
        end if
        return false
    end if
    if not press
        if key = m.transportKey then m.transportKey = ""
        return key = "OK" or key = "play" or key = "playonly" or key = "pause" or key = "replay" or key = "up" or key = "down"
    end if
    if key = "OK" or key = "play" or key = "playonly" or key = "pause"
        if m.transportKey = key then return true
        m.transportKey = key
        m.hudDismissed = false
        if m.seekKey <> "" and (key = "OK" or key = "play")
            finishVodSeek(true)
            return true
        end if
        if m.seekKey <> "" then finishVodSeek(true)
        if key = "playonly"
            m.vodPaused = false
        else if key = "pause"
            m.vodPaused = true
        else
            m.vodPaused = not m.vodPaused
        end if
        m.video.autoplayAfterSeek = not m.vodPaused
        if m.vodPaused
            m.video.control = "pause"
        else
            m.video.control = "resume"
        end if
        showVodHud()
        m.hudTimer.control = "start"
        return true
    end if
    if key = "replay"
        beginVodSeek("replay", -1)
        finishVodSeek(true)
        return true
    end if
    if key = "up" or key = "down"
        m.hudDismissed = false
        showVodHud()
        m.hudTimer.control = "start"
        return true
    end if
    return false
end function

sub onVodState()
    if not m.isVod or not m.video.visible then return
    state = m.video.state
    if state <> "playing" and state <> "paused" and state <> "buffering" then return
    print "VOD state="; state; " position="; m.video.position; " paused="; m.vodPaused; " seeking="; (m.seekKey <> "")
    ' Video may move focus when its playback state changes.
    if m.qualityOpen <> true and m.timeJumpOpen <> true then m.vodInput.setFocus(true)
    if state = "playing" and (m.vodPaused or m.seekKey <> "")
        m.video.control = "pause"
    end if
    if not m.hudDismissed then showVodHud()
    if state = "playing" and not m.vodPaused and m.seekKey = "" then m.hudTimer.control = "start"
end sub
