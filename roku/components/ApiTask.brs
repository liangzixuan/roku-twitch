sub init()
    m.top.functionName = "request"
end sub

sub request()
    port = CreateObject("roMessagePort")
    transfer = CreateObject("roUrlTransfer")
    transfer.setMessagePort(port)
    transfer.setUrl(m.top.server + m.top.path)
    transfer.setCertificatesFile("common:/certs/ca-bundle.crt")
    transfer.initClientCertificates()
    transfer.addHeader("X-App-Key", m.top.appKey)
    transfer.addHeader("Content-Type", "application/json")
    transfer.retainBodyOnError(true)
    if m.top.method = "POST"
        started = transfer.asyncPostFromString(FormatJson(m.top.body))
    else
        started = transfer.asyncGetToString()
    end if
    if not started
        m.top.result = {ok: false, message: "Could not start the request."}
        return
    end if
    event = wait(m.top.timeoutMs, port)
    if type(event) <> "roUrlEvent"
        transfer.asyncCancel()
        m.top.result = {ok: false, message: "Server timed out. Check the computer or NAS."}
        return
    end if
    code = event.getResponseCode()
    body = {}
    responseText = event.getString()
    if responseText <> "" then body = ParseJson(responseText)
    if type(body) <> "roAssociativeArray" then body = {}
    if code < 200 or code >= 300
        m.top.result = apiErrorResult(code, body, event.getFailureReason())
    else
        m.top.result = {ok: true, data: body}
    end if
end sub

function apiErrorResult(code as integer, body as object, reason as string) as object
    message = "Server request failed (code " + code.toStr() + ")."
    errorCode = ""
    if reason <> "" then message += " " + Left(reason, 160)
    if type(body.detail) = "roString" or type(body.detail) = "String"
        message = body.detail + " (HTTP " + code.toStr() + ")"
    else if type(body.detail) = "roAssociativeArray"
        if type(body.detail.message) = "roString" or type(body.detail.message) = "String" then message = body.detail.message
        if type(body.detail.code) = "roString" or type(body.detail.code) = "String" then errorCode = body.detail.code
    end if
    return {ok: false, message: message, status_code: code, error_code: errorCode}
end function
