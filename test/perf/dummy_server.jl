using HTTP

HTTP.listen("0.0.0.0", 8000; max_connections=500) do http
    HTTP.setstatus(http, 200)
    write(http, "OK")
    return
end