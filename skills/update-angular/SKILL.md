---
name: update-angular
description: Ejecuta una migracion Angular major por major mediante la fachada v5.
argument-hint: Major Angular objetivo
user-invocable: true
---

# update-angular

Usa la fachada `scripts/angular-migration.ps1` desde la raiz del proyecto.

El primer incremento expone tres operaciones:

```powershell
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command inspect
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command start -TargetMajor <N>
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command status -RunId <id>
```

El controlador decide la raiz, las versiones y las politicas. El agente no debe fabricar argumentos npm/ng, aceptar saltos de mas de una major ni relajar un fallo con flags de bypass.
