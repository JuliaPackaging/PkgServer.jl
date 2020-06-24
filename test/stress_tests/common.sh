#!/bin/bash

randhex()
{
    openssl rand -hex $1
#    cat /dev/urandom | LC_CTYPE=C tr -dc 'a-f0-9' | fold -w $1 | head -n 1
}

randuuid()
{
    HEX=$(randhex 32)
    echo -n "${HEX:0:8}-${HEX:8:4}-${HEX:12:4}-${HEX:16:4}-${HEX:20:8}"
    #echo -n "$(randhex 8)-$(randhex 4)-$(randhex 4)-$(randhex 4)-$(randhex 12)"
}

randsha1()
{
    echo -n $(randhex 40)
}

server()
{
    echo -n "${JULIA_PKG_SERVER:-http://localhost:8000}"
}

url()
{
    echo -n "$(server)/${1}"
}

echo "Using server $(server) for stress tests"