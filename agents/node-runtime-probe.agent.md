---
name: node-runtime-probe
description: Comprueba si el comando de Copilot CLI puede resolver Node y reporta su version y ruta.
tools: [execute]
user-invocable: true
disable-model-invocation: true
---

Comprueba la visibilidad de Node desde el entorno de comandos de esta sesion de Copilot CLI.

Ejecuta una sola consulta PowerShell que:

1. Resuelva `node` con `Get-Command` sin buscar en rutas alternativas.
2. Si no existe, devuelva JSON con `available: false` y `reason: node_not_on_path`.
3. Si existe, ejecute ese mismo `Source` con `--version` y `-p process.execPath`, y devuelva JSON con `available`, `version`, `executable` y `command`.
4. Si cualquiera de las ejecuciones falla, devuelva `available: false` con `reason: node_execution_failed` y la ruta encontrada.

Devuelve el JSON observado y explica brevemente el resultado. No afirmes que Copilot internamente usa esa version: esta prueba solo confirma que el proceso de comandos puede resolverla por PATH. No edites archivos ni ejecutes otras comprobaciones.
