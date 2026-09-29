# Prerrequisitos del host para Angular Migration v6

Angular Migration v6 requiere Windows, `pwsh.exe` 7+, `copilot.exe`, `fnm.exe`, Node
22.19.0 disponible mediante fnm y el bundle `src/dist/entrypoints/main.mjs`.
`scripts/install-host-prerequisites.ps1` informa el estado; no instala fnm, Node ni
el bundle.

## Preparar el controlador

Desde la raiz del repositorio, confirma que fnm puede seleccionar el runtime fijado y
prepara el bundle reproducible:

```powershell
fnm exec --using 22.19.0 -- node --version
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\prepare-typescript-controller.ps1 -Prepare
```

El preparador usa el `npm-cli.js` junto al Node seleccionado, ejecuta `npm ci
--ignore-scripts` dentro de `src/` y compila el bundle. Sin `-Prepare` solo verifica
que el runtime y el bundle existan.

## Comprobar el host

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-host-prerequisites.ps1
```

El JSON solo indica `ready` si estan disponibles PowerShell, Copilot CLI, fnm, Node
22.19.0 via fnm y el bundle. `-Install` instala, con WinGet, unicamente `pwsh.exe` y
`copilot.exe`; despues abre una terminal nueva y vuelve a ejecutar el comprobador.
La autenticacion de Copilot CLI requiere la sesion interactiva del host y no se valida
por este script.

## Aceptacion pendiente

Un resultado `ready` no es un smoke del plugin cargado por Copilot CLI. La instalacion
en host, el smoke real de Copilot CLI y el piloto Angular con rollback siguen siendo
gates separados y siguen pendientes de aceptacion. No se han ejecutado como parte de
la validacion local del bundle; `ready` no los sustituye.
