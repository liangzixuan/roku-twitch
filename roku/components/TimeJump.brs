function parseJumpTime(value as string, duration as float) as object
    value = value.Trim()
    valid = CreateObject("roRegex", "^[0-9]{1,6}(:[0-9]{2}){0,2}$", "")
    if not valid.isMatch(value) then return {ok: false, message: "Use H:MM:SS, M:SS, or seconds."}
    parts = value.Split(":")
    seconds = Val(parts[0])
    if parts.count() >= 2
        if Val(parts[1]) >= 60 then return {ok: false, message: "Minutes and seconds must be below 60."}
        seconds = seconds * 60 + Val(parts[1])
    end if
    if parts.count() = 3
        if Val(parts[2]) >= 60 then return {ok: false, message: "Seconds must be below 60."}
        seconds = seconds * 60 + Val(parts[2])
    end if
    if duration <= 0 then return {ok: false, message: "Wait for the video duration, then try again."}
    if seconds >= duration then return {ok: false, message: "Enter a time before " + vodTimeText(duration) + "."}
    return {ok: true, position: seconds}
end function

sub openTimeJump()
    if not m.isVod or not m.video.visible then return
    closeQuality()
    m.timeJumpOpen = true
    dialog = CreateObject("roSGNode", "KeyboardDialog")
    dialog.title = "Jump to time"
    dialog.message = "H:MM:SS, M:SS, or seconds. Length: " + vodTimeText(vodDuration())
    dialog.text = vodTimeText(m.video.position)
    dialog.buttons = ["Jump", "Cancel"]
    dialog.observeField("buttonSelected", "onTimeJump")
    dialog.observeField("wasClosed", "onTimeJumpClosed")
    m.top.dialog = dialog
end sub

sub onTimeJump()
    dialog = m.top.dialog
    if dialog.buttonSelected = 0
        result = parseJumpTime(dialog.text, vodDuration())
        if not result.ok
            dialog.message = result.message
            return
        end if
        jumpToPosition(result.position)
    end if
    dialog.close = true
end sub

sub jumpToPosition(position as float)
    m.seekTarget = clampSeek(position, vodDuration())
    m.seekPending = true
    m.hudDismissed = false
    m.video.autoplayAfterSeek = not m.vodPaused
    m.video.seek = m.seekTarget
    showVodHud()
    m.hudTimer.control = "start"
end sub

sub onTimeJumpClosed()
    m.timeJumpOpen = false
    if m.video.visible and not m.recovering then m.vodInput.setFocus(true)
end sub

sub closeTimeJump()
    if m.timeJumpOpen and m.top.dialog <> invalid then m.top.dialog.close = true
    m.timeJumpOpen = false
end sub
