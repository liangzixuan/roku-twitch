sub assertThat(condition as boolean, message as string)
    if not condition
        print "FAIL: " + message
        invalid.FailTest()
    end if
    m.checks += 1
end sub

sub callApi(action as string, path as string, method as string, body as object)
    m.request = {action: action, path: path, method: method, body: body}
end sub

sub loadVods(page as integer)
    m.request = {action: "videos", channel: m.channel, page: page}
end sub

sub showSettings()
    m.view = "menu"
end sub

sub main()
    m.checks = 0
    m.status = {text: ""}
    initLibrary()
    chooseVideo("12345")
    assertThat(m.request.path = "/api/vod/progress/12345", "check progress before deciding how to start")
    assertThat(m.pendingVideoId = "12345", "remember selected recording")
    showResumeChoice({position: 0})
    assertThat(m.request.action = "playvod" and not m.request.body.resume, "unwatched recording starts without prompt")
    playChosenVideo(true)
    assertThat(m.request.body.resume and m.request.body.video_id = "12345", "resume request uses selected recording")
    playChosenVideo(false)
    assertThat(not m.request.body.resume, "start from beginning is explicit")
    m.busy = false
    loadHistory()
    assertThat(m.request.path = "/api/history", "load continue watching list")
    m.busy = true
    m.request = invalid
    loadHistory()
    assertThat(m.request = invalid, "do not interrupt an active request")

    m.view = "home"
    m.followActions = [{kind: "history"}, {kind: "channel", channel: "focused"}, {kind: "channel", channel: "selected"}]
    m.followList = {itemFocused: 1, itemSelected: 2}
    assertThat(focusedChannel() = "focused", "star menu uses focused row rather than last selected row")
    m.followList.itemFocused = 0
    assertThat(focusedChannel() = "", "continue watching row is not a channel")
    m.view = "vods"
    assertThat(focusedChannel() = "", "no channel menu on recording list")
    m.channel = "livechannel"
    m.vodCursors = ["old-page"]
    runChannelChoice(1)
    assertThat(m.request.action = "videos" and m.request.channel = "livechannel", "past broadcasts does not depend on live status")
    assertThat(m.request.page = 0 and m.vodCursors[0] = "", "channel menu resets VOD pagination")
    assertThat(m.vodReturnView = "home", "back returns to Following")
    runChannelChoice(0)
    assertThat(m.request.action = "channel", "watch live rechecks online status")
    runChannelChoice(3)
    assertThat(m.view = "menu", "settings remains available from channel menu")
    m.request = invalid
    runChannelChoice(4)
    assertThat(m.request = invalid, "cancel does not start a video")

    m.followRevision = 0
    m.busy = false
    m.favoriteTarget = {channel_id: "123", pinned: false}
    assertThat(favoriteMenuLabel() = "Pin to top", "unfavorited channel offers pin")
    runChannelChoice(2)
    assertThat(m.request.path = "/api/favorites" and m.request.body.channel_id = "123", "pin targets menu channel ID")
    assertThat(m.request.body.pinned and m.followRevision = 1, "pin invalidates earlier background requests")
    assertThat(not m.favoriteTarget.pinned, "do not apply a favorite before server confirmation")
    m.favoriteTarget.pinned = true
    assertThat(favoriteMenuLabel() = "Unpin", "favorite menu offers unpin")
    runChannelChoice(2)
    assertThat(not m.request.body.pinned, "unpin sends explicit false")
    m.request = invalid
    m.busy = true
    runChannelChoice(2)
    assertThat(m.request = invalid and m.followRevision = 2, "repeated action cannot save while busy")
    m.busy = false
    m.favoriteTarget = invalid
    runChannelChoice(2)
    assertThat(m.request = invalid, "missing channel cannot be pinned")

    m.jobId = "job"
    m.isVod = true
    m.vodHasPosition = false
    body = playbackProgressBody()
    assertThat(body.job_id = "job" and not body.doesExist("position"), "do not save a startup placeholder")
    m.vodHasPosition = true
    m.lastVodPosition = 500.0
    body = playbackProgressBody()
    assertThat(body.position = 500 and not body.doesExist("finished"), "heartbeat saves confirmed position")
    body = playbackProgressBody(true)
    assertThat(body.finished and body.position = 500, "natural finish clears continue watching")
    m.isVod = false
    body = playbackProgressBody(true)
    assertThat(not body.doesExist("position") and not body.doesExist("finished"), "live video never creates VOD progress")
    m.view = "history"
    m.vodActions = [{kind: "video", id: "111", title: "Focused recording"}, {kind: "video", id: "222", title: "Selected before"}, {kind: "back"}]
    m.vodList = {itemFocused: 0, itemSelected: 1}
    assertThat(focusedHistoryItem().id = "111", "manage the focused recording rather than last selected recording")
    m.vodList.itemFocused = 2
    assertThat(focusedHistoryItem() = invalid, "Back row has no recording menu")
    m.vodList.itemFocused = -1
    assertThat(focusedHistoryItem() = invalid, "empty focus has no recording menu")
    m.view = "vods"
    m.vodList.itemFocused = 0
    assertThat(focusedHistoryItem() = invalid, "channel VOD list does not expose saved-history actions")

    m.busy = false
    m.historyTargetId = "111"
    runHistoryChoice(0)
    assertThat(m.request.path = "/api/history/update" and m.request.body.video_id = "111", "remove targets the menu recording")
    assertThat(m.request.body.operation = "remove", "remove operation is explicit")
    runHistoryChoice(1)
    assertThat(m.request.body.operation = "watched", "mark watched operation is explicit")
    m.request = invalid
    runHistoryChoice(2)
    assertThat(m.request = invalid, "cancel keeps the recording")
    m.busy = true
    runHistoryChoice(0)
    assertThat(m.request = invalid, "ignore repeated actions while saving")
    m.busy = false
    m.historyTargetId = ""
    runHistoryChoice(1)
    assertThat(m.request = invalid, "missing target cannot change history")

    m.view = "history"
    m.action = "playvod"
    assertThat(canRemoveUnavailable({error_code: "vod_unavailable"}), "confirmed missing recording offers cleanup")
    assertThat(not canRemoveUnavailable({status_code: 404, message: "Not found"}), "generic 404 does not imply deleted recording")
    assertThat(not canRemoveUnavailable({error_code: "", status_code: 502}), "network failure does not offer deletion")
    m.action = "historyupdate"
    assertThat(not canRemoveUnavailable({error_code: "vod_unavailable"}), "management failure cannot be confused with playback lookup")
    m.view = "vods"
    m.action = "playvod"
    assertThat(not canRemoveUnavailable({error_code: "vod_unavailable"}), "cleanup applies to continue watching only")
    print "PASS: "; m.checks; " Library checks"
end sub
