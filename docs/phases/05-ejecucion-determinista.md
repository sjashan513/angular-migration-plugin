# Fase 5 — Ejecución determinista y reanudable

## 1. Resultado de la fase

Al terminar esta fase, el comando público `run -RunId ID` debe ejecutar o reanudar el salto autorizado hasta una frontera estable:

```text
verified       La migración y todos los checks configurados han pasado.
needs-repair   Un fallo de código tiene contexto y scope reparable.
blocked        Falta una decisión, compatibilidad o precondición externa.
failed         El controlador ha sufrido un error interno no recuperable.
```

Esta fase realiza la migración técnica. No invoca agentes y no publica documentación final.

## 2. Archivos permitidos

Crear:

```text
scripts/helpers/render-package-json.js
tests/unit/StateMachine.Tests.ps1
tests/unit/PackageManifestWriter.Tests.ps1
tests/integration/PipelineExecution.Tests.ps1
tests/fixtures/migrations/
schemas/state.schema.json
schemas/check-result.schema.json
schemas/change-set.schema.json
```

Modificar:

```text
scripts/angular-migration.ps1
scripts/modules/Migration.Core.psm1
scripts/modules/Migration.State.psm1
scripts/modules/Migration.Project.psm1
scripts/modules/Migration.Dependencies.psm1
scripts/modules/Migration.Pipeline.psm1
schemas/manifest.schema.json
schemas/result.schema.json
tests/smoke.ps1
README.md
```

No crear un módulo Git separado. Las operaciones Git son funciones privadas de `Migration.Pipeline.psm1` y los procesos continúan delegados a Core.

## 3. Comando público run

Añadir a la fachada:

```powershell
[string]$RunId
```

Dispatch:

```powershell
'run' { Invoke-MigrationRun -ProjectRoot $projectRoot -RunId $RunId }
```

Firma interna:

```powershell
function Invoke-MigrationRun {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
}
```

`Invoke-MigrationRun` no recibe target, paquetes, checks, flags, rama ni etapa. Todo se obtiene de state y manifest.

## 4. Estado persistido

`state.json` debe validar contra `schemas/state.schema.json` y contener como mínimo:

```json
{
  "schemaVersion": 5,
  "runId": "angular-7-to-8-...",
  "projectRoot": "C:\\repo",
  "sourceMajor": 7,
  "targetMajor": 8,
  "status": "running",
  "stage": "baseline",
  "stageRevision": 0,
  "attempt": 1,
  "migrationStatus": "running",
  "documentationStatus": "pending",
  "initialBranch": "main",
  "initialCommit": "<sha>",
  "migrationBranch": null,
  "checkpointCommit": "<sha>",
  "manifestSha256": null,
  "activeOperation": null,
  "completedOperations": [],
  "lastDiagnostic": null,
  "createdAt": "<utc>",
  "updatedAt": "<utc>"
}
```

`stageRevision` aumenta exactamente en uno por transición confirmada. `completedOperations` contiene identificadores fijos, nunca comandos:

```text
baseline
resolve-manifest
create-branch
update-angular
update-dependencies
install
validate
technical-result
```

## 5. Autoridad de transición

Añadir a `Migration.State.psm1`:

```powershell
function Move-MigrationState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus,
        [Parameter(Mandatory = $true)][string]$ExpectedStage,
        [Parameter(Mandatory = $true)][string]$NewStatus,
        [Parameter(Mandatory = $true)][string]$NewStage,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        $Diagnostic = $null
    )
}
```

La función debe:

1. comprobar ownership;
2. releer state desde disco;
3. comparar status, stage y revision esperados;
4. comprobar la transición contra una tabla cerrada;
5. incrementar revision;
6. escribir atómicamente;
7. releer y verificar;
8. añadir un evento de transición.

Si otro escritor ha avanzado el estado:

```text
blocked / state_revision_conflict
```

No realizar merge de estados.

Tabla de transiciones técnicas:

```powershell
$script:AllowedTransitions = @{
    'running|baseline'            = @('running|resolve', 'blocked|baseline', 'failed|baseline')
    'running|resolve'             = @('running|update-angular', 'blocked|resolve', 'failed|resolve')
    'running|update-angular'      = @('running|update-dependencies', 'needs-repair|update-angular', 'blocked|update-angular', 'failed|update-angular')
    'running|update-dependencies' = @('running|install', 'blocked|update-dependencies', 'failed|update-dependencies')
    'running|install'             = @('running|validate', 'blocked|install', 'failed|install')
    'running|validate'            = @('verified|document', 'needs-repair|validate', 'blocked|validate', 'failed|validate')
    'needs-repair|update-angular' = @('running|update-angular', 'blocked|update-angular', 'failed|update-angular')
    'needs-repair|validate'       = @('running|validate', 'blocked|validate', 'failed|validate')
}
```

Documentación y `completed` se añaden en fase 7.

## 6. Operaciones y eventos

Antes de una operación externa mutante, guardar:

```json
{
  "id": "update-angular",
  "stage": "update-angular",
  "startedAt": "<utc>",
  "checkpointCommit": "<sha>",
  "expectedManifestSha256": "<hash>"
}
```

Evento `operation-started` se persiste antes de ejecutar. Al terminar, evento `operation-finished` incluye exit code, timeout, duración, logs y nuevo commit si existe.

Una operación se considera confirmada únicamente cuando:

1. el proceso termina correctamente;
2. se validan postcondiciones;
3. se crea el checkpoint Git si es mutante;
4. se añade a `completedOperations`;
5. se limpia `activeOperation` mediante escritura de state confirmada.

La existencia de un log o evento no basta para marcarla completada.

## 7. Política Git cerrada

### 7.1 Rama

El controlador crea una rama dedicada antes de la primera modificación:

```text
migration/angular-{sourceMajor}-to-{targetMajor}-{runIdSuffix}
```

`runIdSuffix` son los últimos ocho caracteres hexadecimales del run ID. El nombre completo se valida contra:

```regex
^migration/angular-[0-9]+-to-[0-9]+-[a-f0-9]{8}$
```

Comando estructurado:

```text
git switch -c <branch> <initialCommit>
```

Si `git switch` no está disponible, usar exactamente:

```text
git checkout -b <branch> <initialCommit>
```

No usar otro fallback. Si la rama ya existe, bloquear con `migration_branch_exists`; no reutilizarla.

### 7.2 Checkpoints

Commits automáticos permitidos:

```text
chore(migration): Angular {source} to {target} schematics [{runId}]
chore(migration): align dependencies for Angular {target} [{runId}]
fix(migration): repair {fingerprint} attempt {attempt} [{runId}]
docs(migration): document Angular {source} to {target} [{runId}]
```

Los dos primeros pertenecen a esta fase. El de reparación se usa en fase 6 y el documental en fase 7.

Antes de `git add`:

1. leer `git status --porcelain=v1 -z --untracked-files=all`;
2. parsear NUL, incluidas rutas renombradas;
3. normalizar cada ruta dentro de project root;
4. rechazar cambios en `.github/`, `.git/`, `.angular-migration/` y `docs/` durante la migración técnica;
5. construir un array de rutas exactas;
6. ejecutar `git add -- <ruta1> <ruta2> ...` sin shell;
7. ejecutar `git commit -m <mensaje fijo>`.

No usar `git add .`, globs, `--all`, `--allow-empty` ni mensajes elegidos por el agente.

## 8. Renderizado de package.json

PowerShell 5.1 puede alterar excesivamente el formato al serializar JSON. Crear `scripts/helpers/render-package-json.js` como transformador puro:

```text
stdin: JSON con packageText, mode y dependencias resueltas
stdout: package.json final
stderr: diagnóstico
exit 0: correcto
exit 1: input inválido
```

Input conceptual:

```json
{
  "mode": "exact",
  "packageText": "{\n  ...\n}",
  "dependencies": [
    {
      "name": "@angular/core",
      "section": "dependencies",
      "targetVersion": "8.2.14",
      "writeSpec": "^8.2.14"
    }
  ]
}
```

Modos:

```text
exact       Escribe targetVersion exacto antes de generar lockfile.
declared    Escribe writeSpec después de verificar el lockfile exacto.
```

El helper debe:

1. usar solo módulos estándar de Node;
2. detectar LF/CRLF;
3. detectar tabs o número de espacios de indentación;
4. preservar orden de propiedades y orden de secciones;
5. modificar únicamente dependencias existentes en la sección declarada;
6. rechazar paquetes ausentes, duplicados o movidos de sección;
7. preservar newline final si existía;
8. no escribir archivos;
9. emitir exclusivamente el JSON transformado en stdout.

Core añade `Write-MigrationTextAtomic`, con el mismo patrón temporal/reemplazo que JSON atómico. Pipeline captura stdout y escribe `package.json`.

## 9. Orden exacto de run

Pseudocódigo normativo:

```powershell
function Invoke-MigrationRun {
    Assert-ActiveRunOwnership
    $state = Read-And-ValidateState
    $manifest = Read-And-ValidateManifest
    Assert-ProjectMatchesRun
    Assert-ManifestHashWhenResolved

    while ($state.status -eq 'running') {
        switch ($state.stage) {
            'baseline'            { Invoke-BaselineStage }
            'resolve'             { Invoke-ResolveStage }
            'update-angular'      { Invoke-AngularUpdateStage }
            'update-dependencies' { Invoke-DependencyUpdateStage }
            'install'             { Invoke-InstallStage }
            'validate'            { Invoke-ValidationStage }
            default               { throw invalid_stage }
        }
        $state = Read-And-ValidateState
    }

    return Convert-StateToEnvelopeResult
}
```

El bucle no reintenta un proceso fallido automáticamente. Solo avanza después de una postcondición confirmada.

## 10. Etapa baseline

1. exigir branch y HEAD iniciales;
2. working tree limpio;
3. ejecutar la baseline de fase 3;
4. si pasa, añadir `baseline` a completedOperations;
5. mover a `running/resolve`.

Fallo configurado o timeout:

```text
blocked / baseline_check_failed
```

Liberar lock porque el proyecto no fue modificado y este run no puede continuar. Para reintentar, el usuario corrige la baseline y crea un run nuevo.

## 11. Etapa resolve

1. ejecutar resolver de fase 4;
2. validar y publicar manifest exacto;
3. verificar Node activo;
4. añadir `resolve-manifest`;
5. crear rama dedicada;
6. guardar `migrationBranch` y checkpoint inicial;
7. añadir `create-branch`;
8. mover a `running/update-angular`.

La respuesta de `run` puede incluir:

```json
{
  "documentationReady": true,
  "documentationContextCommand": "documentation-context"
}
```

Esto informa al orquestador de que puede iniciar investigación en paralelo; Pipeline no invoca al agente.

## 12. Etapa update-angular

### 12.1 Ejecutable

Después de la baseline debe existir:

```text
node_modules/.bin/ng.cmd
```

Resolver esa ruta dentro del proyecto. No usar una CLI global y no usar `npx`.

### 12.2 Comando principal

Construir desde manifest:

```text
ng.cmd update @angular/core@<exact> @angular/cli@<exact>
```

Si `@angular/cli` no estaba en el proyecto, la fase 4 debe haber bloqueado; no instalarla implícitamente aquí.

No añadir flags. En particular quedan prohibidos:

```text
--force
--allow-dirty
--next
--from
--to
--migrate-only
--create-commits
--skip-confirmation
```

La pipeline controla el target exacto, el working tree y los commits.

### 12.3 Paquetes con migrations propias

Fase 4 debe incluir metadata `ngUpdate`. Para cada dependencia Angular-aware con migrations declaradas y cambio de versión:

```text
ng.cmd update <package>@<exact>
```

Orden:

1. core + cli;
2. paquetes oficiales Angular restantes en orden alfabético;
3. paquetes externos Angular-aware en orden alfabético.

No ejecutar `ng update` para dependencias ordinarias.

### 12.4 Postcondiciones

- package.json sigue siendo JSON válido;
- package-lock.json sigue siendo JSON válido;
- no hay cambios en rutas protegidas;
- cada paquete Angular modificado corresponde a una entrada del manifest;
- no apareció una major superior al target;
- logs completos existen;
- no hay proceso vivo después del timeout.

Si el comando termina no cero:

1. restaurar archivos tracked al checkpoint anterior;
2. eliminar únicamente rutas untracked que no existían en el inventario previo de la etapa;
3. no usar `git clean`;
4. verificar working tree limpio;
5. clasificar:
   - error de código con rutas fuente identificables: `needs-repair/update-angular`;
   - conflicto de versiones, peers o integridad: `blocked/update-angular`;
   - fallo de rollback o del controlador: `failed/update-angular`.

Un `needs-repair` en esta etapa repara el código anterior a la migration. Tras registrar el repair, se crea un checkpoint de reparación y se ejecuta de nuevo la etapa desde limpio.

Si pasa, crear checkpoint schematics y mover a `running/update-dependencies`.

## 13. Etapa update-dependencies

Objetivo: aplicar exactamente todas las decisiones del manifest sin permitir una segunda resolución.

Orden:

1. verificar hash del manifest;
2. renderizar package.json en modo `exact`;
3. escribirlo atómicamente;
4. ejecutar:

```text
npm install --package-lock-only
```

5. leer el lockfile;
6. comprobar que cada dependencia directa quedó bloqueada exactamente en `targetVersion`;
7. renderizar package.json en modo `declared` usando `writeSpec`;
8. escribirlo atómicamente;
9. verificar que cada rango declarado admite la versión bloqueada;
10. comprobar que ningún paquete directo fue añadido, eliminado o movido sin decisión en manifest;
11. crear checkpoint de dependencias;
12. mover a `running/install`.

No pasar la lista de paquetes a `npm install`; package.json exacto ya contiene el conjunto autorizado. No usar `npm update`.

Si npm selecciona una versión distinta a manifest:

```text
blocked / lockfile_resolution_mismatch
```

Restaurar al checkpoint schematics antes de bloquear.

## 14. Etapa install

Ejecutar exactamente:

```text
npm ci
npm ls --all
```

Postcondiciones:

- package.json y lockfile no cambian durante `npm ci`;
- todos los directos coinciden con manifest;
- `npm ls --all` devuelve cero;
- no hay `invalid`, `extraneous` o `missing`;
- logs existen.

Fallo de peer/integridad:

```text
blocked / dependency_install_failed
```

No se entrega al Implementer porque este no puede editar dependencias.

Éxito: añadir `install` y mover a `running/validate`.

## 15. Etapa validate

No repetir `install` ni `dependency-tree`; ya pertenecen a la etapa anterior. Ejecutar en orden:

```text
typecheck
lint
unit-test
build
e2e
```

Solo se ejecutan checks `configured`. `not-configured` se conserva como tal.

Si todos pasan:

1. crear `result.json` técnico;
2. validar schema;
3. calcular hash;
4. guardar `migrationStatus: verified`;
5. mover state a `verified/document`;
6. mantener lock hasta completar documentación.

Si falla uno:

1. detener los checks posteriores;
2. crear fingerprint;
3. crear failure context;
4. mover a `needs-repair/validate`;
5. mantener lock.

## 16. Scope reparable

El failure context no se basa únicamente en texto del modelo. Se construye desde check y configuración del proyecto:

| Check | Rutas editables |
| --- | --- |
| `typecheck` | `sourceRoot/**`, tsconfig del proyecto y ficheros referenciados por el diagnóstico dentro de la raíz. |
| `lint` | `sourceRoot/**` y configuración lint detectada. |
| `unit-test` | `sourceRoot/**`, tests dentro del proyecto y configuración del runner detectado. |
| `build` | `sourceRoot/**`, `angular.json`, tsconfig, polyfills, browserslist y ficheros referenciados dentro de la raíz. |
| `e2e` | Directorio e2e detectado y su configuración; nunca inventar ruta. |
| `update-angular` | Solo rutas fuente/config referenciadas por el error; package.json y lockfile siempre excluidos. |

Exclusiones absolutas para Implementer:

```text
.git/**
.github/**
.angular-migration/** excepto inbox/repair.json
docs/**
package.json
package-lock.json
plugin.json
```

Si no se puede construir un scope no vacío y seguro, el resultado es `blocked / repair_scope_unknown`, no `needs-repair`.

## 17. Fingerprint y reintentos

Fingerprint canónico:

```text
SHA256(
  stage + "\n" +
  checkId + "\n" +
  normalizedErrorCode + "\n" +
  sortedDiagnosticPaths + "\n" +
  normalizedFirstRelevantMessage
)
```

Normalización elimina rutas absolutas de la raíz, timestamps, números de línea variables y whitespace repetido. No elimina nombres de símbolos ni códigos de error.

Máximo tres reparaciones registradas para el mismo fingerprint. Al intentar la cuarta:

```text
blocked / repair_attempt_limit_reached
```

No incrementar intento por volver a consultar status o repair-context.

## 18. Reanudación e interrupciones

Al entrar en `run`:

1. verificar ownership y lock;
2. validar state, manifest y hashes;
3. comprobar rama y HEAD esperados;
4. inspeccionar `activeOperation`;
5. comparar eventos y completedOperations;
6. decidir con esta tabla:

| Situación | Acción |
| --- | --- |
| Operación no mutante iniciada sin finish | Repetirla. |
| Operación mutante tiene checkpoint confirmado | No repetir; limpiar activeOperation y avanzar. |
| Operación mutante interrumpida con working tree sucio | Restaurar checkpoint y borrar solo nuevos untracked inventariados; luego dejar `blocked / interrupted_operation_rolled_back`. |
| State dice completada pero checkpoint falta | `failed / checkpoint_missing`. |
| HEAD no coincide con checkpoint | `blocked / git_head_changed`. |
| Manifest hash no coincide | `failed / manifest_integrity_failed`. |
| Lock pertenece a otro run | `blocked / run_not_owner`. |

No reanudar automáticamente después de un rollback de operación mutante. Una nueva llamada explícita a `run` puede continuar cuando status haya sido revisado y autorizado por el contrato correspondiente.

## 19. result.json técnico

Forma mínima:

```json
{
  "schemaVersion": 5,
  "runId": "angular-7-to-8-...",
  "sourceMajor": 7,
  "targetMajor": 8,
  "status": "verified",
  "migrationStatus": "verified",
  "documentationStatus": "pending",
  "manifestSha256": "<hash>",
  "initialCommit": "<sha>",
  "finalTechnicalCommit": "<sha>",
  "changedFiles": [],
  "dependencyChanges": [],
  "checks": [],
  "repairs": [],
  "warnings": [],
  "verifiedAt": "<utc>",
  "resultSha256": "<hash>"
}
```

`changedFiles` se obtiene con Git, no del agente. `dependencyChanges` se deriva de manifest y lock final. `checks` referencia logs. `result.json` no contiene stdout/stderr completos.

Después de guardar `resultSha256`, el resultado técnico es inmutable. Fase 7 guarda estado documental en state y un input documental separado; no reescribe la evidencia técnica.

## 20. Liberación de lock

| Estado | Lock |
| --- | --- |
| `running` | Mantener |
| `needs-repair` | Mantener |
| `verified` con docs pendientes | Mantener |
| `completed` | Liberar después de verificar escritura final |
| `blocked` definitivo | Liberar después de persistir diagnóstico |
| `failed` definitivo | Liberar después de persistir diagnóstico |

La eliminación comprueba que `active.lock.runId` coincide. Nunca eliminar un lock ajeno.

## 21. Tests obligatorios

### Máquina de estados

Cubrir todas las transiciones permitidas y al menos estas denegadas:

- baseline -> validate;
- needs-repair -> verified;
- verified -> running;
- failed -> running;
- completed -> cualquier estado;
- revisión desactualizada;
- runId distinto;
- target alterado.

### Git

- rama nueva correcta;
- rama ya existente bloquea;
- detached HEAD bloquea antes de mutar;
- ruta protegida modificada bloquea antes de commit;
- checkpoint contiene exactamente rutas autorizadas;
- ningún commit usa `git add .`;
- no se hace push;
- rollback restaura tracked;
- rollback borra solo untracked creados por la etapa;
- untracked preexistente nunca se borra.

### package.json y lockfile

- formato LF y CRLF;
- indentación con espacios y tabs;
- orden de propiedades preservado;
- modo exact y declared;
- paquete ausente se rechaza;
- sección incorrecta se rechaza;
- lock distinto del manifest bloquea;
- todas las dependencias directas se verifican.

### Pipeline

- happy path simulado hasta verified;
- baseline fallida no crea rama;
- resolver bloqueado no modifica proyecto;
- ng update recibe versiones exactas;
- no se usa CLI global ni npx;
- dependency update usa manifest, no registry;
- npm ci y npm ls se ejecutan en orden;
- e2e ausente queda not-configured;
- check final fallido produce needs-repair;
- install fallido produce blocked;
- process start failure produce failed;
- reanudación no repite checkpoint;
- manifest alterado produce failed;
- result técnico es inmutable;
- lock se mantiene en verified.

Todos los procesos externos se simulan. Ningún test unitario o de integración consulta internet o instala Angular real.

## 22. Checklist de salida

- [ ] Fachada publica `run` sin argumentos libres.
- [ ] State schema y tabla de transiciones están implementados.
- [ ] Cada operación tiene start, finish, logs y postcondiciones.
- [ ] Se crea una rama dedicada sin reutilización.
- [ ] Commits usan mensajes y rutas cerrados.
- [ ] Angular update usa CLI local y versiones exactas.
- [ ] Package.json se aplica primero exacto y después recupera estilo de rango.
- [ ] Lockfile coincide exactamente con manifest.
- [ ] Todas las dependencias directas están verificadas.
- [ ] Checks finales producen verified o needs-repair.
- [ ] Failure context contiene fingerprint y scope seguro.
- [ ] La cuarta reparación idéntica se bloqueará.
- [ ] Interrupciones se recuperan desde checkpoints sin `git clean`.
- [ ] result.json técnico es inmutable.
- [ ] Lock se mantiene hasta documentación.
- [ ] No se ha invocado ningún agente desde PowerShell.

La fase 6 no comienza hasta que una integración simulada recorra todas las etapas y una segunda llamada a `run` demuestre que no repite operaciones confirmadas.
