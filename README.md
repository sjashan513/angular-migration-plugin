# angular-migration

Plugin interno para migraciones Angular auditables en Windows con PowerShell 5.1.

## Estado

El primer incremento implementa la inspeccion y el arranque de un unico salto `N -> N+1`.
La resolucion de versiones, la ejecucion de cambios y los checks finales se incorporaran en incrementos posteriores.

## Uso

Ejecuta la fachada desde la raiz de un proyecto Angular CLI:

```powershell
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command inspect
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command start -TargetMajor 8
powershell -NoProfile -File <plugin>\scripts\angular-migration.ps1 -Command status -RunId <run-id>
```

La salida estandar contiene exactamente un JSON v5. Los errores humanos y el progreso se reservan para stderr.

## Precondiciones

- Proyecto Angular CLI con `package.json`, `angular.json` y `package-lock.json` en la raiz.
- npm como gestor de paquetes.
- Working tree Git limpio.
- Node y npm disponibles.
- El destino debe ser exactamente el major actual mas uno.

Cada run se guarda bajo `.angular-migration/runs/<run-id>/`. El lock de ownership impide dos runs mutantes sobre el mismo proyecto.

## Estructura

```text
agents/
  migration-implementer.agent.md
  migration-documenter.agent.md
scripts/
  angular-migration.ps1
  modules/
    Migration.Core.psm1
    Migration.State.psm1
    Migration.Project.psm1
schemas/
  manifest.schema.json
  result.schema.json
tests/
  smoke.ps1
docs/
  adr/
```

La instalacion del plugin no escribe artefactos en el propio plugin: la fachada usa el directorio actual como raiz del proyecto.

## Prueba local

```powershell
powershell -NoProfile -File tests\smoke.ps1
```

MIT
