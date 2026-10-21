sub initLibrary()
    m.pendingVideoId = ""
    m.stopBody = {}
    m.historyTargetId = ""
    m.historyFocus = 0
    m.favoriteTarget = invalid
end sub

sub loadHistory()
    if m.busy then return
    if m.view <> "history" then m.historyFocus = 0
    m.status.text = "Loading continue watching..."
    callApi("history", "/api/history", "GET", {})
end sub

sub showHistory(d as object)
    content = CreateObject("roSGNode", "ContentNode")
    m.vodActions = []
    for each video in d.videos
        ratio = 0.0
        if video.duration_seconds > 0 then ratio = video.position / video.duration_seconds
        info = {subtitle: video.channel + "  |  Watched " + vodTimeText(video.position) + " / " + vodTimeText(video.duration_seconds), progressRatio: ratio, showProgress: video.position > 0}
        addVodRow(content, video.title, {kind: "video", id: video.id, title: video.title, info: info, metadata: video})
    end for
    addVodRow(content, "Back", {kind: "back"})
    m.vodList.content = content
    if m.historyFocus >= m.vodActions.count() then m.historyFocus = m.vodActions.count() - 1
    m.vodList.jumpToItem = m.historyFocus
    m.view = "history"
    restoreFocus()
    showVodDetails(m.vodActions[m.historyFocus])
    m.status.text = "Choose a recording to continue."
    if d.videos.count() = 0 then m.status.text = "No unfinished recordings yet."
end sub

sub chooseVideo(videoId as string)
    m.pendingVideoId = videoId
    m.status.text = "Checking saved progress..."
    callApi("progress", "/api/vod/progress/" + videoId, "GET", {})
end sub

sub showResumeChoice(d as object)
    if d.position <= 0
        playChosenVideo(false)
        return
    end if
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Continue watching?"
    dialog.buttons = ["Resume at " + vodTimeText(d.position), "Start from beginning", "Cancel"]
    dialog.observeField("buttonSelected", "onResumeChoice")
    m.top.dialog = dialog
end sub

sub onResumeChoice()
    choice = m.top.dialog.buttonSelected
    m.top.dialog.close = true
    restoreFocus()
    if choice = 0 or choice = 1 then playChosenVideo(choice = 0)
end sub

sub playChosenVideo(resume as boolean)
    m.status.text = "Opening VOD..."
    callApi("playvod", "/api/vod/play", "POST", {video_id: m.pendingVideoId, resume: resume})
end sub

function focusedChannel() as string
    if m.view <> "home" then return ""
    index = m.followList.itemFocused
    if index < 0 or index >= m.followActions.count() then return ""
    action = m.followActions[index]
    if action.kind = "channel" then return action.channel
    return ""
end function

sub showChannelMenu(channel as string)
    m.channel = channel
    m.selectedChannel = channel
    m.favoriteTarget = invalid
    for each profile in m.followed
        if profile.login = channel then m.favoriteTarget = {channel_id: profile.id, pinned: profile.pinned = true}
    end for
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = channel
    dialog.buttons = ["Watch live", "Past broadcasts", favoriteMenuLabel(), "Settings", "Cancel"]
    dialog.observeField("buttonSelected", "onChannelMenu")
    m.top.dialog = dialog
end sub

sub onChannelMenu()
    choice = m.top.dialog.buttonSelected
    m.top.dialog.close = true
    restoreFocus()
    runChannelChoice(choice)
end sub

sub runChannelChoice(choice as integer)
    m.vodReturnView = "home"
    if choice = 0
        m.status.text = "Opening " + m.channel + "..."
        callApi("channel", "/api/channel/" + m.channel, "GET", {})
    else if choice = 1
        m.vodCursors = [""]
        loadVods(0)
    else if choice = 2
        toggleFavorite()
    else if choice = 3
        showSettings()
    end if
end sub

function favoriteMenuLabel() as string
    if m.favoriteTarget <> invalid
        if m.favoriteTarget.pinned then return "Unpin"
    end if
    return "Pin to top"
end function

sub toggleFavorite()
    if m.busy or m.favoriteTarget = invalid then return
    ' Discard any older list response after this change, including failed saves.
    m.followRevision++
    m.status.text = "Saving favorite..."
    callApi("favorite", "/api/favorites", "POST", {channel_id: m.favoriteTarget.channel_id, pinned: not m.favoriteTarget.pinned})
end sub

function playbackProgressBody(finished = false as boolean) as object
    body = {job_id: m.jobId}
    if m.recoveryToken <> invalid and m.recoveryToken <> "" then body.recovery_id = m.recoveryToken
    if m.isVod
        if m.vodHasPosition then body.position = m.lastVodPosition
        if finished then body.finished = true
    end if
    return body
end function

function focusedHistoryItem() as dynamic
    if m.view <> "history" then return invalid
    index = m.vodList.itemFocused
    if index < 0 or index >= m.vodActions.count() then return invalid
    item = m.vodActions[index]
    if item.kind = "video" then return item
    return invalid
end function

sub showHistoryMenu(item as object)
    m.historyTargetId = item.id
    m.historyFocus = m.vodList.itemFocused
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = item.title
    dialog.buttons = ["Remove from continue watching", "Mark as watched", "Cancel"]
    dialog.observeField("buttonSelected", "onHistoryMenu")
    m.top.dialog = dialog
end sub

sub onHistoryMenu()
    choice = m.top.dialog.buttonSelected
    m.top.dialog.close = true
    restoreFocus()
    runHistoryChoice(choice)
end sub

sub runHistoryChoice(choice as integer)
    if choice = 0
        updateHistory("remove")
    else if choice = 1
        updateHistory("watched")
    end if
end sub

sub updateHistory(operation as string)
    if m.busy or m.historyTargetId = "" then return
    m.status.text = "Updating continue watching..."
    callApi("historyupdate", "/api/history/update", "POST", {video_id: m.historyTargetId, operation: operation})
end sub

function canRemoveUnavailable(result as object) as boolean
    return m.view = "history" and m.action = "playvod" and result.error_code = "vod_unavailable"
end function

sub showUnavailableHistory()
    m.historyTargetId = m.pendingVideoId
    m.historyFocus = m.vodList.itemFocused
    dialog = CreateObject("roSGNode", "Dialog")
    dialog.title = "Recording unavailable"
    dialog.message = "This recording is no longer available. Remove its saved progress?"
    dialog.buttons = ["Remove from continue watching", "Keep"]
    dialog.observeField("buttonSelected", "onUnavailableHistory")
    m.top.dialog = dialog
end sub

sub onUnavailableHistory()
    choice = m.top.dialog.buttonSelected
    m.top.dialog.close = true
    restoreFocus()
    if choice = 0 then updateHistory("remove")
end sub
