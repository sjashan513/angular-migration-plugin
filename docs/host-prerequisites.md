# Prerrequisitos del host

La fase 8 necesita dos programas instalados en Windows:

- `pwsh.exe`: PowerShell 7+, usado por los hooks de Copilot CLI.
- `copilot.exe`: GitHub Copilot CLI, que carga el plugin, sus agentes, la skill y los hooks.

El repositorio no distribuye esos ejecutables ni los crea durante la migracion.

## Comprobar

Ejecuta el comprobador desde la raiz del repositorio:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-host-prerequisites.ps1
```

El resultado es JSON. El estado `ready` significa que ambos ejecutables estan en
`PATH`. El estado `blocked` lista los ejecutables ausentes.

## Instalar en Windows

El script usa los identificadores oficiales de WinGet y solo instala cuando se
indica explicitamente `-Install`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-host-prerequisites.ps1 -Install
```

Despues de la instalacion, abre una terminal nueva y ejecuta de nuevo el modo de
comprobacion. La primera sesion de Copilot CLI puede requerir autenticacion
interactiva con `/login`; no guardes tokens en este repositorio ni en la evidencia
de release.

La instalacion oficial de Copilot CLI requiere una suscripcion activa y, en
Windows, PowerShell 6 o superior. La ruta WinGet evita la dependencia de Node del
host. La documentacion oficial esta en
[Installing GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-in-the-cli).

## Continuacion de la release

Cuando el comprobador devuelva `ready`, reinicia la sesion de Copilot CLI y ejecuta
la instalacion directa, la instalacion desde el marketplace local y el piloto real
Angular 7 -> 8. Esos pasos son evidencia nueva y no deben sustituirse por un
fixture local.
