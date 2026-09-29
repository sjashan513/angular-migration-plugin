# Controlador TypeScript Angular Migration v6

## Runtime y estado de release

`src/` contiene el controlador TypeScript; `scripts/angular-migration-ts.ps1` lo
inicia con Node 22.19.0 seleccionado por fnm y
`src/dist/entrypoints/main.mjs`. Los agentes y la skill activos son los de v6.
`plugin.json` y `marketplace.json` declaran v6.0.0. La fachada, politica y suites
PowerShell v5 se retiraron. El formato de estado persistido v5 no es compatible y no
se convierte automaticamente; conserva o archiva esos datos antes de operar en un
proyecto que todavia los tenga.

## Contrato CLI

Cada invocacion acepta opciones como pares nombre/valor y emite un envelope JSON
schema 1. `success` sale con codigo 0, `failed` con 1 y `blocked` con 2. El facade
valida los comandos y es la autoridad para transiciones, artefactos y estado; no se
debe editar `.angular-migration/run.json` directamente.

| Comando                                                           | Proposito                                                   |
| ----------------------------------------------------------------- | ----------------------------------------------------------- |
| `inspect`                                                         | Lee el major Angular actual y hechos del proyecto.          |
| `discover`                                                        | Construye el plan para `target-major` sin crear un run.     |
| `approve-runtime`                                                 | Aprueba con `plan-hash` vigente y `--confirmed true`.       |
| `start`                                                           | Crea el run tras discovery listo.                           |
| `run`                                                             | Ejecuta o reanuda con `run-id`.                             |
| `status`                                                          | Lee el estado actual del proyecto.                          |
| `baseline-dependency-context`                                     | Presenta los peers faltantes del baseline.                  |
| `approve-baseline-dependencies`                                   | Aplica la propuesta vigente tras confirmacion.              |
| `skip-check`                                                      | Registra una omision opcional, con razon y confirmacion.    |
| `repair-context`, `record-repair`                                 | Obtiene y registra una entrega de reparacion run-bound.     |
| `documentation-research-context`, `record-documentation-research` | Obtiene y registra research.                                |
| `documentation-publish-context`                                   | Obtiene el borrador o la propuesta hasheada de publicacion. |
| `publish-documentation`                                           | Publica la propuesta vigente tras confirmacion.             |

Todos requieren `--project-root`. Los comandos que actuan sobre un run requieren
`--run-id`; `discover` y `start` requieren `--target-major`. Las aprobaciones usan
hash vigente y `--confirmed true`. No hay comando de skip por lotes en este CLI.

## Flujo de documentacion

La investigacion se entrega primero al inbox run-bound y el controlador la valida y
registra. Despues de que el run este tecnicamente `verified`,
`documentation-publish-context` devuelve un borrador con `proposalHash: null`, los
ocho paths requeridos y el inbox de submission. El documenter escribe solo `{path,
content}` por archivo; no calcula hashes ni crea los archivos finales. Una segunda
consulta valida el contenido y devuelve una propuesta hasheada. El usuario debe
confirmar esa propuesta antes de `publish-documentation`; el controlador escribe los
ocho documentos de forma atomica.

Los agentes v6 escriben unicamente sus submissions en
`.angular-migration/repair-inbox/` o `.angular-migration/documentation-inbox/`. El hook
valida el estado, el run y la submission; el controlador valida y aplica los cambios
permitidos o publica los documentos. El implementer no edita directamente fuentes del
proyecto. El dispatcher solo selecciona la politica TS desde `run.json`; si detecta
`active.lock` sin un `run.json`, bloquea el formato legado v5. Si hay un run activo y
falta el runtime TypeScript, la decision es deny/block.

## Preparacion y verificacion local

`scripts/prepare-typescript-controller.ps1 -Prepare` instala las dependencias de
`src/` con `npm ci --ignore-scripts` bajo Node 22.19.0 y produce el bundle ESM
autocontenido. El bundle se puede ejecutar sin `node_modules`; el wrapper de PowerShell
bloquea si falta fnm o el bundle.

La verificacion local debe cubrir build, suites unitarias/integracion del paquete,
smoke de fixtures y preparacion desde un checkout limpio. No equivale a probar que el
host Copilot carga el plugin. El smoke real de Copilot CLI y un piloto Angular con
rollback estan reservados para la aceptacion del usuario y no deben marcarse como
completados por estas pruebas.
