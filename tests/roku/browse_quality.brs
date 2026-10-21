sub assertThat(condition as boolean, message as string)
    if not condition
        print "FAIL: " + message
        invalid.FailTest()
    end if
    m.checks++
end sub

sub callApi(action as string, path as string, method as string, body as object)
    m.request = {action: action, path: path, method: method, body: body}
end sub

sub schedule(action as string, seconds as integer)
    m.timerAction = action
end sub

sub startVideo(d as object)
    m.startedVideo = d
    m.startedPaused = m.qualityResumePaused
end sub

sub restoreFocus()
    m.focusRestored = true
end sub

sub showFollowing()
    m.view = "home"
end sub

sub finishVodSeek(commit as boolean)
    m.seekKey = ""
end sub

function playbackProgressBody() as object
    body = {job_id: m.jobId}
    if m.isVod and m.vodHasPosition then body.position = m.lastVodPosition
    return body
end function

function vodTimeText(seconds as float) as string
    return Int(seconds).toStr()
end function

sub main()
    m.checks = 0
    video = {created_at: "2026-10-21T00:00:00Z", duration: "1h", duration_seconds: 3600, position: 900}
    info = vodListInfo(video)
    assertThat(info.progressRatio = 0.25 and info.showProgress, "watched recording has proportionate progress bar")
    assertThat(Instr(1, info.subtitle, "Watched 900") > 0, "row shows saved watching time")
    video.delete("position")
    info = vodListInfo(video)
    assertThat(not info.showProgress and info.progressRatio = 0, "older service and unwatched recordings have no progress bar")
    video.position = 9000
    assertThat(vodListInfo(video).progressRatio = 1, "progress cannot exceed row width")
    video.position = -1
    assertThat(not vodListInfo(video).showProgress, "negative progress is hidden")
    video.duration_seconds = 0
    video.position = 100
    assertThat(vodListInfo(video).progressRatio = 0, "zero duration does not divide by zero")

    m.busy = false
    m.status = {text: ""}
    m.searchQuery = "name + space"
    m.searchCursors = ["", "a+/="]
    loadSearch(1)
    assertThat(m.request.path = "/api/search?q=name%20%2B%20space&cursor=a%2B%2F%3D", "search query and cursor are encoded separately")
    assertThat(m.requestedSearchPage = 1, "search tracks requested page")
    m.busy = true
    m.request = invalid
    loadSearch(0)
    assertThat(m.request = invalid, "busy search does not replace active request")
    m.busy = false
    m.timerAction = ""
    m.searchList = {itemSelected: 0}
    m.searchActions = [{kind: "channel", channel: "found"}, {kind: "page", page: 1}, {kind: "back"}]
    onSearchSelected()
    assertThat(m.request.path = "/api/channel/found", "search selection rechecks live status")
    assertThat(m.vodReturnView = "search" and m.channel = "found", "recordings opened from search return to search")
    m.searchList.itemSelected = 1
    onSearchSelected()
    assertThat(m.request.action = "search" and m.requestedSearchPage = 1, "search next-page row requests correct page")
    m.searchList.itemSelected = 2
    onSearchSelected()
    assertThat(m.view = "home", "search Back row returns home")

    m.video = {visible: true, control: "play"}
    m.vodInput = {setFocus: sub(value as boolean)
    end sub}
    m.qualityPanel = {visible: true}
    m.qualityStatus = {text: ""}
    m.qualityList = {itemSelected: 1}
    m.qualityChoices = ["best", "720p60"]
    m.qualityOpen = true
    m.qualityChanging = false
    m.qualityResumePaused = false
    m.qualityBackHeld = false
    m.qualityOptionsHeld = false
    m.timer = {control: "start"}
    m.heartbeat = {control: "start"}
    m.timerAction = ""
    m.jobId = "job1"
    m.qualityTargetJob = "job1"
    m.isVod = true
    m.vodPaused = true
    m.vodHasPosition = true
    m.lastVodPosition = 321.5
    m.seekPending = false
    requestQualities()
    assertThat(m.request.path = "/api/player/qualities?job_id=job1", "quality discovery belongs to current session")
    assertThat(qualityLabel("best") = "Highest available" and qualityLabel("720p60") = "720p60", "quality choices have readable labels")
    onQualitySelected()
    assertThat(m.request.action = "quality" and m.request.body.position = 321.5, "switch uses confirmed VOD position")
    assertThat(m.request.body.quality = "720p60" and m.request.body.job_id = "job1", "switch sends chosen quality and session")
    assertThat(m.qualityResumePaused and m.qualityChanging, "paused intent is saved through switch")
    beginQualityPlayback({id: "job1", state: "ready", play_start: 321.5})
    assertThat(m.startedPaused and m.startedVideo.play_start = 321.5, "new video receives paused intent and saved position")
    assertThat(not m.qualityOpen and not m.qualityPanel.visible, "accepted quality closes panel")

    m.video.visible = true
    m.qualityOpen = true
    m.qualityChanging = false
    m.qualityResumePaused = false
    m.vodHasPosition = false
    m.request = invalid
    onQualitySelected()
    assertThat(m.request = invalid, "VOD cannot switch from an unconfirmed startup position")
    m.vodHasPosition = true
    m.seekPending = true
    onQualitySelected()
    assertThat(m.request = invalid, "VOD cannot switch while a seek remains pending")
    m.seekPending = false
    m.vodPaused = false
    onQualitySelected()
    assertThat(not m.qualityResumePaused and m.video.control = "pause", "playing VOD is held at its position while switching")
    qualityError("Network unavailable")
    assertThat(not m.vodPaused and m.video.control = "resume", "failed switch restores playing state")
    assertThat(not m.qualityChanging and m.qualityStatus.text = "Network unavailable", "failed switch remains visible and retryable")
    m.vodPaused = true
    onQualitySelected()
    qualityError("Network unavailable")
    assertThat(m.vodPaused and m.video.control = "pause", "failed switch keeps paused VOD paused")

    m.busy = true
    m.request = invalid
    onQualitySelected()
    assertThat(m.request = invalid, "held OK cannot issue duplicate switches")
    m.busy = false
    m.timerAction = "qualities"
    assertThat(handleQualityKey("back", true), "Back closes quality panel")
    assertThat(not m.qualityOpen and m.video.visible and m.timerAction = "", "closing quality stops polling and keeps video")
    assertThat(handleQualityKey("back", true), "held Back does not exit video after closing panel")
    assertThat(handleQualityKey("back", false) and not m.qualityBackHeld, "Back release clears held state")
    assertThat(not handleQualityKey("back", true), "next Back can reach video controls")
    m.request = invalid
    receiveQualities({state: "starting"})
    assertThat(m.timerAction = "" and m.request = invalid, "late discovery response cannot reopen closed menu")

    m.qualityOpen = true
    m.qualityChanging = false
    m.video.visible = true
    m.isVod = false
    m.vodPaused = false
    m.transportKey = ""
    m.qualityResumePaused = false
    onQualitySelected()
    assertThat(not m.request.body.doesExist("position"), "live switch never sends VOD progress")
    beginQualityPlayback({id: "newjob", state: "starting"})
    assertThat(m.jobId = "newjob" and m.timerAction = "player", "live switch tracks new session during buffering")
    assertThat(not m.video.visible and m.qualityChanging, "old player events are ignored while new live stream starts")
    m.video.visible = true
    m.qualityChanging = false
    m.vodPaused = false
    assertThat(handleQualityKey("OK", true) and m.vodPaused, "live OK pauses playback with shared input focus")
    assertThat(handleQualityKey("OK", true) and m.vodPaused, "held live OK does not toggle twice")
    handleQualityKey("OK", false)
    assertThat(handleQualityKey("OK", true) and not m.vodPaused, "next live OK resumes playback")
    m.video.visible = false
    m.qualityOptionsHeld = false
    assertThat(not handleQualityKey("options", true), "home star remains available to channel menu")
    assertThat(not m.qualityOptionsHeld, "home dialog cannot leave playback star marked held")
    nodes = {vodDetailsMeta: {text: ""}, vodCoverFallback: {text: ""}}
    m.top = {nodes: nodes, findNode: function(name as string) as object
        return m.nodes[name]
    end function}
    m.vodThumbnail = {uri: "", visible: false, loadStatus: "loading"}
    m.vodDetailsTitle = {text: "", focused: false, setFocus: sub(value as boolean)
        m.focused = value
    end sub, isInFocusChain: function() as boolean
        return m.focused
    end function}
    m.vodList = {focused: false, setFocus: sub(value as boolean)
        m.focused = value
    end sub}
    longTitle = "A full recording title that remains available in the scrollable details pane"
    showVodDetails({kind: "video", metadata: {title: longTitle, created_at: "2026-10-21T00:00:00Z", duration_seconds: 3600, thumbnail: "https://static-cdn.jtvnw.net/cover.jpg"}})
    assertThat(m.vodDetailsTitle.text = longTitle, "details retain full title without truncation")
    assertThat(nodes.vodDetailsMeta.text = "2026-10-21  |  3600", "details show recording date and length")
    assertThat(not m.vodThumbnail.visible and nodes.vodCoverFallback.text = "No preview", "loading cover leaves fallback")
    m.vodThumbnail.loadStatus = "ready"
    onVodThumbnailLoad()
    assertThat(m.vodThumbnail.visible, "loaded cover appears")
    m.vodThumbnail.loadStatus = "failed"
    onVodThumbnailLoad()
    assertThat(not m.vodThumbnail.visible, "failed cover keeps list usable")
    showVodDetails({kind: "video", metadata: {title: "Old history record", duration_seconds: 60}})
    assertThat(m.vodThumbnail.uri = "" and m.vodDetailsTitle.text = "Old history record", "history without cover metadata still shows full title")
    showVodDetails({kind: "page"})
    assertThat(m.vodThumbnail.uri = "" and m.vodDetailsTitle.text = "" and nodes.vodCoverFallback.text = "", "page row clears previous cover and title")
    m.view = "vods"
    m.video.visible = false
    m.recovering = false
    m.detailsBackHeld = false
    assertThat(handleVodDetailsKey("right", true) and m.vodDetailsTitle.focused, "Right focuses scrollable title")
    assertThat(not handleVodDetailsKey("down", true), "native title receives scrolling keys")
    assertThat(handleVodDetailsKey("back", true) and m.vodList.focused, "Back returns from title to list")
    m.vodDetailsTitle.focused = false
    assertThat(handleVodDetailsKey("back", true), "held Back does not exit after leaving title")
    assertThat(handleVodDetailsKey("back", false) and not m.detailsBackHeld, "release clears details Back latch")
    assertThat(not handleVodDetailsKey("back", true), "next Back can exit list")
    m.video.visible = true
    assertThat(not handleVodDetailsKey("right", true), "details cannot intercept video seek")
    print "PASS: "; m.checks; " Browse and quality checks"
end sub
