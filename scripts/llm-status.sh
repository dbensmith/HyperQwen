#!/bin/bash
if /usr/bin/curl -sf -m 5 -o /dev/null http://127.0.0.1:18020/health; then
  echo on
else
  echo off
fi
