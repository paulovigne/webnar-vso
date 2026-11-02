#!/bin/bash

# Inicia um container PostgreSQL em background para servir como banco de dados da aplicação.
# O nome do container é fixo para facilitar a identificação e gerenciamento do serviço.
docker run -d --name postgres-vso \
  # Define o usuário administrativo do PostgreSQL.
  -e POSTGRES_USER=postgres \
  # Define a senha do usuário administrador.
  -e POSTGRES_PASSWORD=postgres \
  # Cria o banco de dados inicial da aplicação.
  -e POSTGRES_DB=goapp \
  # Publica a porta 5432 do container para a máquina host.
  -p 5432:5432 \
  # Usa a imagem oficial do PostgreSQL 15.
  postgres:15