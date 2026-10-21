sub assertThat(condition as boolean, message as string)
    if not condition
        print "FAIL: " + message
        invalid.FailTest()
    end if
    m.checks++
end sub

sub callApi(action as string, path as string, method as string, body as object)
    m.request = {action: action, path: path, body: body}
end sub

sub schedule(action as string, seconds as integer)
    m.timerAction = action
    m.delay = seconds
end sub

sub startVideo(d as object)
    m.started = d
    m.startedPaused = m.qualityResumePaused
    m.video.visible = true
end sub

sub stopPlayback(message as string, finished = false as boolean)
    m.stopped = message
    m.cancelToken = m.recoveryToken
    clearRecovery()
    m.video.visible = false
end sub

sub closeQuality()
    m.qualityOpen = false
end sub

sub fixture()
    m.video = {visible: true, state: "playing", control: "play", position: 160.0, duration: 7200.0}
    m.isVod = true
    m.vodPaused = false
    m.vodHasPosition = true
    m.lastVodPosition = 160.0
    m.seekKey = ""
    m.seekTarget = 800.0
    m.seekPending = true
    m.qualityChanging = false
    m.qualityResumePaused = false
    m.timeJumpOpen = false
    m.qualityOpen = false
    m.top = {dialog: invalid}
    m.status = {text: ""}
    m.stallTimer = {control: "start"}
    m.stableTimer = {control: "start"}
    m.seekTimer = {control: "start"}
    m.hudTimer = {control: "start"}
    m.heartbeat = {control: "start"}
    m.vodHud = {visible: true}
    m.vodInput = {setFocus: sub(value as boolean)
        m.focused = value
    end sub}
    m.timerAction = ""
    m.request = invalid
    m.stopped = ""
    clearRecovery()
    rememberRecovery({id: "job1", recovery_id: "session1", kind: "vod", play_start: 50})
end sub

sub main()
    m.checks = 0
    assertThat(parseJumpTime("1:23:45", 10000).position = 5025, "hours minutes and seconds")
    assertThat(parseJumpTime("83:45", 10000).position = 5025, "minutes may exceed 59")
    assertThat(parseJumpTime("5025", 10000).position = 5025, "plain seconds")
    assertThat(parseJumpTime(" 0:00 ", 100).position = 0, "zero and surrounding spaces")
    for each bad in ["", "1:60", "1:60:00", "1:23:60", "-1", "1.5", "1:2", "a", "1:00:00:00"]
        assertThat(not parseJumpTime(bad, 10000).ok, "reject malformed time: " + bad)
    end for
    assertThat(not parseJumpTime("100", 100).ok, "reject exact end")
    assertThat(not parseJumpTime("101", 100).ok, "reject beyond end")
    assertThat(not parseJumpTime("0", 0).ok, "wait for unknown duration")
    fixture()
    m.vodTime = {text: ""}
    m.vodFill = {width: 0}
    m.playIcon = {visible: false}
    m.pauseIcon = {visible: false}
    m.vodPaused = true
    jumpToPosition(5025)
    assertThat(m.video.seek = 5025 and m.seekPending, "jump sets target without claiming it was played")
    assertThat(not m.video.autoplayAfterSeek and m.vodPaused, "jump keeps paused intent")
    assertThat(m.lastVodPosition = 160, "jump does not overwrite confirmed progress")
    m.vodPaused = false
    jumpToPosition(600)
    assertThat(m.video.autoplayAfterSeek and m.video.seek = 600, "playing jump resumes")
    assertThat(m.vodHud.visible and m.hudTimer.control = "start", "jump briefly shows timeline")
    m.timeJumpOpen = true
    m.top.dialog = {close: false}
    closeTimeJump()
    assertThat(m.top.dialog.close and not m.timeJumpOpen, "stop can close time dialog")

    fixture()
    m.vodPaused = true
    beginRecovery("network")
    assertThat(m.recovering and not m.video.visible and m.video.control = "stop", "recovery stops old video")
    assertThat(m.recoveryPosition = 160 and m.recoveryPaused, "recovery keeps confirmed position and pause")
    assertThat(m.timerAction = "recover" and m.delay = 2 and m.recoveryRetries = 0, "first attempt waits 2 seconds")
    assertThat(not m.vodHud.visible and m.heartbeat.control = "stop" and m.seekTimer.control = "stop", "recovery cancels playback timers and preview")
    requestRecovery()
    assertThat(m.request.path = "/api/player/recover" and m.request.body.position = 160, "recovery sends confirmed position")
    assertThat(m.request.body.recovery_id = "session1" and m.request.body.attempt = 1, "recovery belongs to logical session")
    m.action = "heartbeat"
    assertThat(handleRecoveryResult({ok: true, data: {state: "ready"}}), "late heartbeat is ignored during recovery")
    assertThat(m.recovering and m.timerAction = "recover", "late heartbeat cannot cancel retry")
    m.action = "recover"
    handleRecoveryResult({ok: true, data: {id: "job2", recovery_id: "session1", state: "starting", kind: "vod", play_start: 160}})
    assertThat(m.recovering and m.jobId = "job2" and m.timerAction = "player", "starting recovery polls new job")
    m.action = "player"
    handleRecoveryResult({ok: true, data: {id: "job2", recovery_id: "session1", state: "ready", kind: "vod", play_start: 160}})
    assertThat(not m.recovering and m.startedPaused and m.started.play_start = 160, "ready response restores paused playback")
    assertThat(m.recoveryRetries = 1 and m.recoverySequence = 1, "brief success does not reset retry limit")
    m.vodPaused = false
    beginRecovery("again")
    assertThat(m.delay = 5, "second attempt waits 5 seconds")
    requestRecovery()
    m.action = "recover"
    handleRecoveryResult({ok: false, status_code: 502, message: "network"})
    assertThat(m.recovering and m.delay = 10, "third attempt waits 10 seconds")
    requestRecovery()
    handleRecoveryResult({ok: false, message: "timeout"})
    assertThat(not m.recovering and Instr(1, m.stopped, "3 attempts") > 0, "stops after three failed attempts")
    assertThat(m.cancelToken = "session1", "final stop retains logical token for cancellation")

    for each code in [400, 401, 403, 404, 409, 410, 422]
        fixture()
        beginRecovery("network")
        requestRecovery()
        m.action = "recover"
        handleRecoveryResult({ok: false, status_code: code, message: "terminal"})
        assertThat(m.stopped = "terminal" and not m.recovering, "terminal error stops retries: " + code.toStr())
    end for
    fixture()
    m.action = "heartbeat"
    handleRecoveryResult({ok: false, status_code: 409, message: "job cleaned up"})
    assertThat(m.recovering, "lost server job can recover using logical session")
    fixture()
    m.action = "heartbeat"
    handleRecoveryResult({ok: false, status_code: 401, message: "sign in"})
    assertThat(not m.recovering and m.stopped = "sign in", "heartbeat auth failure stops immediately")

    fixture()
    m.video.state = "buffering"
    m.vodPaused = true
    watchPlaybackState()
    onPlaybackStalled()
    assertThat(m.stallTimer.control = "stop" and not m.recovering, "paused buffering never triggers recovery")
    m.vodPaused = false
    m.seekKey = "right"
    watchPlaybackState()
    onPlaybackStalled()
    assertThat(not m.recovering, "held seek does not trigger recovery")
    m.seekKey = ""
    watchPlaybackState()
    assertThat(m.stallTimer.control = "start", "buffering while playing starts stall timer")
    onPlaybackStalled()
    assertThat(m.recovering, "expired stall timer starts recovery")
    fixture()
    m.recoveryRetries = 2
    m.recoverySequence = 5
    m.video.state = "playing"
    watchPlaybackState()
    assertThat(m.stableTimer.control = "start", "playing starts stability timer")
    onPlaybackStable()
    assertThat(m.recoveryRetries = 0 and m.recoverySequence = 5, "stable playback resets retry budget but keeps sequence")
    m.recoveryRetries = 2
    m.video.state = "paused"
    onPlaybackStable()
    assertThat(m.recoveryRetries = 2, "late stability event while paused cannot reset budget")
    fixture()
    m.vodHasPosition = false
    beginRecovery("startup")
    assertThat(m.recoveryPosition = 50, "startup recovery preserves resume position before first frame")
    fixture()
    m.isVod = false
    beginRecovery("live failure")
    requestRecovery()
    assertThat(not m.request.body.doesExist("position"), "live recovery has no VOD position")
    fixture()
    m.qualityChanging = true
    m.qualityResumePaused = false
    m.vodPaused = true
    beginRecovery("quality switch failure")
    assertThat(not m.recoveryPaused, "temporary quality-switch pause is not user pause")
    fixture()
    m.recoveryToken = ""
    beginRecovery("old service")
    assertThat(m.stopped = "old service" and not m.recovering, "older service fails without retry loop")
    print "PASS: "; m.checks; " Recovery and time checks"
end sub
