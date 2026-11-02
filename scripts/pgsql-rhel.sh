#!/bin/bash

# Inicia um container PostgreSQL em background para servir como banco de dados da aplicação.
# O nome do container é fixo para facilitar a identificação e gerenciamento do serviço.
docker run -d --name postgres-vso \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=goapp \
  -p 5432:5432 \
  postgres:15