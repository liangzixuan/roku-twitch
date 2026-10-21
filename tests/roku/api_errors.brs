sub main()
    checks = 0
    result = apiErrorResult(404, {detail: {code: "vod_unavailable", message: "Recording unavailable"}}, "")
    if result.error_code <> "vod_unavailable" or result.status_code <> 404 or result.message <> "Recording unavailable" then invalid.FailTest()
    checks++
    result = apiErrorResult(404, {detail: "Not Found"}, "")
    if result.error_code <> "" or result.message <> "Not Found (HTTP 404)" then invalid.FailTest()
    checks++
    result = apiErrorResult(401, {detail: "Sign in again"}, "")
    if result.error_code <> "" or result.status_code <> 401 then invalid.FailTest()
    checks++
    result = apiErrorResult(422, {detail: [{message: "Bad field"}]}, "")
    if result.error_code <> "" or result.ok then invalid.FailTest()
    checks++
    result = apiErrorResult(-1, {}, "Connection failed")
    if result.error_code <> "" or result.status_code <> -1 then invalid.FailTest()
    checks++
    print "PASS: "; checks; " API error checks"
end sub
