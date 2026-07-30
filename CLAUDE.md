# DELTA Windows Installer

This repository contains the official Windows Server installer for the DELTA application.

Objectives:
- Docker-based deployment
- Windows Server 2025
- Docker Desktop + WSL2 backend
- Native NGINX reverse proxy
- Production-ready installation
- Preserve compatibility with dts_shared_binary

Rules:
- Follow the approved architecture documents under /docs.
- Do not introduce architectural changes without updating the design documents.
- Prefer PowerShell scripts over batch files.
- Maintain idempotent installation steps.
- Keep Docker images minimal and reproducible.