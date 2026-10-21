sub init()
    m.top.backgroundColor = "0x171323FF"
    m.status = m.top.findNode("status")
    m.menu = m.top.findNode("menu")
    m.vodList = m.top.findNode("vodList")
    m.timer = m.top.findNode("timer")
    m.heartbeat = m.top.findNode("heartbeat")
    m.video = m.top.findNode("video")
    initVodControls()
    initFollowing()
    initLibrary()
    initBrowse()
    initQuality()
    initRecovery()
    m.timer.observeField("fire", "onTimer")
    m.heartbeat.observeField("fire", "onHeartbeat")
    m.video.observeField("state", "onVideoState")
    m.menu.observeField("itemSelected", "onSelect")
    m.vodList.observeField("itemSelected", "onVodSelected")
    m.busy = false
    m.loginId = ""
    m.channel = ""
    m.timerAction = ""
    m.stopRequested = false
    m.stopMessage = "Playback stopped."
    m.view = "home"
    m.jobId = ""
    m.vodActions = []
    m.vodCursors = [""]
    m.vodPage = 0
    menu = CreateObject("roSGNode", "ContentNode")
    for each title in ["Sign in to Twitch", "Check account", "Choose channel", "Check channel subscription", "Play live channel", "Browse VODs", "Sign out / cancel login", "Back to Following"]
        item = menu.createChild("ContentNode")
        item.title = title
    end for
    m.menu.content = menu
    showFollowing()
    m.config = ParseJson(ReadAsciiFile("pkg:/config.json"))
    if m.config = invalid
        m.status.text = "Setup is missing. Run setup on the computer or NAS and install the generated package."
        return
    end if
    m.top.findNode("serverAddress").text = "Server: " + m.config.server
    callApi("account", "/api/account", "GET", {})
end sub

sub callApi(action as string, path as string, method as string, body as object)
    if m.busy or m.config = invalid then return
    m.busy = true
    m.action = action
    m.task = CreateObject("roSGNode", "ApiTask")
    m.task.server = m.config.server
    m.task.appKey = m.config.appKey
    m.task.path = path
    m.task.method = method
    m.task.body = body
    if action = "heartbeat" or action = "recover" or action = "player" then m.task.timeoutMs = 15000
    m.task.observeField("result", "onResult")
    m.task.control = "RUN"
end sub

sub requestFollowPage(path as string)
    m.followTask = CreateObject("roSGNode", "ApiTask")
    m.followTask.server = m.config.server
    m.followTask.appKey = m.config.appKey
    m.followTask.path = path
    m.followTask.method = "GET"
    m.followTask.observeField("result", "onFollowResult")
    m.followTask.control = "RUN"
end sub

sub schedule(action as string, seconds as integer)
    m.timerAction = action
    m.timer.duration = seconds
    m.timer.control = "start"
end sub

sub onTimer()
    if m.busy
        schedule(m.timerAction, 1)
        return
    end if
    if m.timerAction = "login" and m.loginId <> ""
        callApi("poll", "/api/login/" + m.loginId, "GET", {})
    else if m.timerAction = "player"
        callApi("player", "/api/player", "GET", {})
    else if m.timerAction = "recover"
        requestRecovery()
    else if m.timerAction = "qualities" and m.qualityOpen
        requestQualities()
    end if
end sub

sub onHeartbeat()
    if m.video.visible and not m.busy and m.jobId <> ""
        callApi("heartbeat", "/api/player/heartbeat", "POST", playbackProgressBody())
    end if
end sub

sub onSelect()
    if m.busy then return
    choice = m.menu.itemSelected
    if m.loginId <> "" and choice <> 6 then return
    if m.timerAction = "player" and choice <> 6 then return
    if choice = 0
        m.status.text = "Requesting a login code..."
        callApi("login", "/api/login", "POST", {})
    else if choice = 1
        callApi("account", "/api/account", "GET", {})
    else if choice = 2
        dialog = CreateObject("roSGNode", "KeyboardDialog")
        dialog.title = "Twitch channel name"
        dialog.text = m.channel
        dialog.buttons = ["Save", "Cancel"]
        dialog.observeField("buttonSelected", "onChannel")
        m.top.dialog = dialog
    else if choice = 3 or choice = 4 or choice = 5
        if m.channel = ""
            m.status.text = "Choose a channel first. Enter its name without a URL."
        else if choice = 3
            callApi("subscription", "/api/subscription/" + m.channel, "GET", {})
        else if choice = 4
            m.status.text = "Starting " + m.channel + "..."
            callApi("play", "/api/play", "POST", {channel: m.channel})
        else
            m.vodReturnView = "menu"
            m.vodCursors = [""]
            loadVods(0)
        end if
    else if choice = 7
        showFollowing()
        loadFollowing()
    else if choice = 6
        m.timer.control = "stop"
        m.timerAction = ""
        if m.loginId <> ""
            m.loginId = ""
            callApi("cancel", "/api/login/cancel", "POST", {})
        else
            callApi("logout", "/api/logout", "POST", {})
        end if
    end if
end sub

sub onChannel()
    dialog = m.top.dialog
    if dialog.buttonSelected = 0
        channel = LCase(dialog.text.Trim())
        validName = CreateObject("roRegex", "^[a-z0-9_]{1,25}$", "")
        if validName.isMatch(channel)
            m.channel = channel
            m.status.text = "Channel: " + m.channel
        else
            m.status.text = "Enter a Twitch channel name using letters, numbers or underscores."
        end if
    end if
    dialog.close = true
    m.menu.setFocus(true)
end sub

sub loadVods(page as integer)
    if page <> m.vodPage then m.vodFocusId = ""
    m.requestedPage = page
    m.status.text = "Loading past broadcasts for " + m.channel + "..."
    cursor = m.vodCursors[page]
    path = "/api/videos/" + m.channel + "?cursor=" + cursor.EncodeUriComponent()
    callApi("videos", path, "GET", {})
end sub

sub addVodRow(content as object, title as string, action as object)
    item = content.createChild("ContentNode")
    item.title = title
    item.addFields({progressRatio: 0.0, showProgress: false})
    if action.info <> invalid
        item.shortDescriptionLine1 = action.info.subtitle
        item.progressRatio = action.info.progressRatio
        item.showProgress = action.info.showProgress
    end if
    m.vodActions.push(action)
end sub

sub showVods(d as object)
    m.vodPage = m.requestedPage
    m.vodActions = []
    content = CreateObject("roSGNode", "ContentNode")
    for each video in d.videos
        addVodRow(content, video.title, {kind: "video", id: video.id, info: vodListInfo(video), metadata: video})
    end for
    if d.cursor <> ""
        m.vodCursors[m.vodPage + 1] = d.cursor
        addVodRow(content, "Next page", {kind: "page", page: m.vodPage + 1})
    end if
    if m.vodPage > 0
        addVodRow(content, "Previous page", {kind: "page", page: m.vodPage - 1})
    end if
    addVodRow(content, "Back", {kind: "back"})
    m.vodList.content = content
    selected = 0
    for i = 0 to m.vodActions.count() - 1
        if m.vodActions[i].id = m.vodFocusId then selected = i
    end for
    m.vodList.jumpToItem = selected
    m.view = "vods"
    restoreFocus()
    showVodDetails(m.vodActions[selected])
    if d.videos.count() = 0
        m.status.text = "No saved past broadcasts found for " + m.channel + "."
    else
        m.status.text = "Past broadcasts: " + m.channel + " (page " + (m.vodPage + 1).toStr() + ")"
    end if
end sub

sub onVodSelected()
    if m.busy or m.timerAction = "player" then return
    action = m.vodActions[m.vodList.itemSelected]
    if action.kind = "video"
        m.vodFocusId = action.id
        chooseVideo(action.id)
    else if action.kind = "page"
        loadVods(action.page)
    else if m.view = "history"
        showFollowing()
    else
        returnFromVods()
    end if
end sub

sub restoreFocus()
    m.menu.visible = m.view = "menu"
    m.vodList.visible = m.view = "vods" or m.view = "history"
    m.top.findNode("vodDetails").visible = m.vodList.visible
    m.searchList.visible = m.view = "search"
    m.followList.visible = m.view = "home"
    m.top.findNode("followDetails").visible = m.view = "home"
    m.top.findNode("serverAddress").visible = m.view = "menu"
    m.top.findNode("footer").text = "OK: Watch  |  * Channel menu / Settings"
    m.top.findNode("heading").text = "Following"
    m.status.height = 65
    if m.view = "search"
        m.top.findNode("heading").text = "Search channels"
        m.top.findNode("footer").text = "OK: Open  |  Back: Following"
        m.searchList.setFocus(true)
    else if m.view = "vods" or m.view = "history"
        m.top.findNode("heading").text = "Past broadcasts"
        if m.view = "history" then m.top.findNode("heading").text = "Continue watching"
        m.top.findNode("footer").text = "Back: Following  |  * Settings"
        if m.view = "history" then m.top.findNode("footer").text = "*: Manage recording  |  Back: Following"
        if m.view = "vods" and m.vodReturnView = "menu" then m.top.findNode("footer").text = "Back: Settings"
        if m.view = "vods" and m.vodReturnView = "search" then m.top.findNode("footer").text = "Back: Search results"
        m.vodList.setFocus(true)
    else if m.view = "menu"
        m.top.findNode("heading").text = "Settings"
        m.top.findNode("footer").text = "Personal Twitch 0.10.0  |  Back: Following"
        m.status.height = 175
        m.menu.setFocus(true)
    else
        m.followList.setFocus(true)
    end if
end sub

sub startVideo(d as object)
    rememberRecovery(d)
    resetVodControls()
    m.qualityChanging = false
    m.isVod = d.kind = "vod"
    m.video.enableUI = false
    m.video.enableTrickPlay = false
    m.video.autoplayAfterSeek = true
    m.timerAction = ""
    m.jobId = d.id
    content = CreateObject("roSGNode", "ContentNode")
    content.streamFormat = "hls"
    content.HttpCertificatesFile = "common:/certs/ca-bundle.crt"
    if d.kind = "vod"
        content.url = d.url
        content.title = d.title
        content.live = false
        content.playStart = d.play_start
        m.seekTarget = d.play_start * 1.0
        m.seekPending = d.play_start > 0
        content.length = d.duration_seconds
        ' The pairing key is only for the local server.
        content.HttpHeaders = []
    else
        content.url = m.config.server + d.path
        content.title = d.channel
        content.live = true
        content.HttpHeaders = ["X-App-Key:" + m.config.appKey]
    end if
    m.video.setHttpAgent(CreateObject("roHttpAgent"))
    m.video.content = content
    m.video.visible = true
    m.vodInput.setFocus(true)
    m.vodPaused = m.qualityResumePaused
    m.qualityResumePaused = false
    m.video.autoplayAfterSeek = not m.vodPaused
    m.video.control = "play"
    if m.isVod
        showVodHud()
        m.hudTimer.control = "start"
    end if
    m.heartbeat.control = "start"
end sub

sub stopPlayback(message as string, finished = false as boolean)
    m.stopBody = playbackProgressBody(finished)
    if m.recovering and m.isVod then m.stopBody.position = m.recoveryPosition
    clearRecovery()
    closeTimeJump()
    closeQuality()
    m.qualityChanging = false
    m.qualityResumePaused = false
    resetVodControls()
    m.heartbeat.control = "stop"
    m.timer.control = "stop"
    m.timerAction = ""
    m.jobId = ""
    m.video.visible = false
    m.video.control = "stop"
    restoreFocus()
    m.stopMessage = message
    m.status.text = message
    if m.busy
        m.stopRequested = true
    else
        callApi("stop", "/api/stop", "POST", m.stopBody)
    end if
end sub

sub onResult()
    result = m.task.result
    m.task.unobserveField("result")
    m.busy = false
    if m.stopRequested
        m.stopRequested = false
        m.timerAction = ""
        if result.ok and (m.action = "quality" or m.action = "play" or m.action = "playvod" or m.action = "recover")
            if result.data.id <> invalid then m.stopBody.job_id = result.data.id
        end if
        callApi("stop", "/api/stop", "POST", m.stopBody)
        return
    end if
    if handleRecoveryResult(result) then return
    if not result.ok
        m.timer.control = "stop"
        m.timerAction = ""
        m.status.text = result.message
        if m.action = "qualities" or m.action = "quality"
            if result.status_code = 404 then result.message = "Update the computer service after watching to use this feature."
            qualityError(result.message)
            return
        end if
        if m.action = "player" and m.qualityChanging
            stopPlayback(result.message)
            return
        end if
        if canRemoveUnavailable(result) then showUnavailableHistory()
        if (m.action = "historyupdate" or m.action = "favorite") and result.status_code = 404 then m.status.text = "Update the computer service after watching to use this feature."
        if m.action = "heartbeat" then stopPlayback(result.message)
        ' Permit checking an account if a successful login response was lost.
        m.loginId = ""
        return
    end if
    d = result.data
    if m.action = "login"
        m.loginId = d.id
        m.status.text = "On your phone, open twitch.tv/activate?public=true" + Chr(10) + "Enter code: " + d.user_code + Chr(10) + "Use the account with your channel subscription."
        schedule("login", d.interval)
    else if m.action = "poll"
        if d.state = "pending"
            schedule("login", d.interval)
        else
            m.loginId = ""
            m.timerAction = ""
            if d.state = "complete"
                m.view = "home"
                callApi("account", "/api/account", "GET", {})
            else
                m.status.text = "Login expired or was declined. Select Sign in to try again."
            end if
        end if
    else if m.action = "account"
        if m.account.login <> d.login
            m.followed = []
            m.homeReady = false
            m.followRevision++
        end if
        m.account = d
        if m.view = "home" or d.follows_ready and not m.homeReady
            showFollowing()
            loadFollowing()
        else if d.signed_in
            m.status.text = "Signed in: " + d.login + Chr(10)
            if d.playback_ready
                m.status.text += "Playback identity verified."
            else
                m.status.text += d.message
            end if
        else
            showFollowing()
        end if
    else if m.action = "channel"
        openChannel(d)
    else if m.action = "subscription"
        if d.subscribed
            m.status.text = "Subscribed to " + d.channel + ". Ad-free playback still needs a viewing test."
        else
            m.status.text = "No active subscription found for " + d.channel + "."
        end if
    else if m.action = "search"
        showSearch(d)
    else if m.action = "qualities"
        receiveQualities(d)
    else if m.action = "quality"
        beginQualityPlayback(d)
    else if m.action = "favorite"
        applyFavorite(d)
    else if m.action = "historyupdate"
        loadHistory()
    else if m.action = "history"
        showHistory(d)
    else if m.action = "progress"
        showResumeChoice(d)
    else if m.action = "videos"
        showVods(d)
    else if m.action = "play" or m.action = "playvod" or m.action = "player"
        rememberRecovery(d)
        if d.state = "ready"
            startVideo(d)
        else if d.state = "starting"
            schedule("player", 2)
        else
            m.timerAction = ""
            m.qualityChanging = false
            m.qualityResumePaused = false
            restoreFocus()
            m.status.text = "Playback stopped."
            if d.message <> invalid then m.status.text = d.message
        end if
    else if m.action = "heartbeat"
        if d.state <> "ready"
            message = "Playback session ended. Select the video again."
            if d.message <> "" then message = d.message
            beginRecovery(message)
        end if
    else if m.action = "logout"
        clearRecovery()
        m.followRevision++
        m.account = {signed_in: false, follows_ready: false}
        m.followed = []
        m.homeReady = false
        showFollowing()
    else if m.action = "cancel"
        m.status.text = "Login cancelled."
    else if m.action = "stop"
        m.status.text = m.stopMessage
        if m.view = "home" then loadFollowing()
        if m.view = "history" then loadHistory()
        if m.view = "vods" then loadVods(m.vodPage)
    end if
end sub

sub onVideoState()
    if not m.video.visible then return
    if m.qualityChanging then return
    watchPlaybackState()
    onVodState()
    if not m.isVod and m.video.state = "playing" and m.vodPaused then m.video.control = "pause"
    if m.video.state = "error"
        beginRecovery("Cannot play this video. Check playback login and access to the recording, then try again.")
    else if m.video.state = "finished"
        stopPlayback("Playback finished.", true)
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if m.recovering
        if press and key = "back" then stopPlayback("Playback stopped.")
        return true
    end if
    if m.timeJumpOpen then return false
    if handleVodDetailsKey(key, press) then return true
    if handleQualityKey(key, press) then return true
    if m.qualityOpen then return false
    if m.qualityChanging and press and key = "back"
        stopPlayback("Playback stopped.")
        return true
    end if
    if handleVodKey(key, press) then return true
    if press and key = "options" and not m.video.visible and not m.busy and m.timerAction = ""
        historyItem = focusedHistoryItem()
        channel = focusedChannel()
        if historyItem <> invalid
            showHistoryMenu(historyItem)
        else if channel <> ""
            showChannelMenu(channel)
        else if m.view = "menu"
            showFollowing()
        else
            showSettings()
        end if
        return true
    end if
    if press and key = "back"
        if m.video.visible or m.timerAction = "player"
            stopPlayback("Playback stopped.")
            return true
        end if
        if m.busy and (m.action = "play" or m.action = "playvod" or m.action = "quality")
            stopPlayback("Playback stopped.")
            return true
        end if
        if m.view = "menu"
            if not m.busy
                if m.loginId <> ""
                    m.timer.control = "stop"
                    m.timerAction = ""
                    m.loginId = ""
                    callApi("cancel", "/api/login/cancel", "POST", {})
                end if
                showFollowing()
            end if
            return true
        end if
        if m.view = "history" or m.view = "search"
            if not m.busy then showFollowing()
            return true
        end if
        if m.view = "vods"
            if not m.busy
                returnFromVods()
            end if
            return true
        end if
    end if
    return false
end function
