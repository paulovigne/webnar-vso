#!/bin/bash

docker run -d --name postgres-vso \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=goapp \
  -p 5432:5432 \
  postgres:15