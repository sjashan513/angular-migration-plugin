# Fase 3 — Inspección completa y baseline

## 1. Resultado de la fase

Al terminar esta fase, el controlador debe conocer con precisión qué proyecto va a migrar, qué herramientas y checks existen y si el proyecto funciona antes de modificarlo. La fase no actualiza Angular ni cambia dependencias.

El resultado técnico esperado es una función interna capaz de ejecutar una baseline reproducible y devolver uno de estos resultados:

```text
passed       El proyecto actual supera todos los checks configurados.
blocked      El proyecto ya estaba roto, falta una precondición o un check no puede ejecutarse.
failed       El propio controlador no pudo ejecutar o persistir la baseline.
```

La baseline nunca produce `needs-repair`, porque todavía no se ha realizado ninguna migración. Un fallo preexistente debe repararse fuera del run y comenzar después un run nuevo.

## 2. Precondiciones

Antes de empezar, debe existir y pasar el smoke test del incremento anterior. Deben funcionar:

- `inspect` sin escritura;
- `start -TargetMajor N` con salto secuencial;
- lock único;
- lectura y escritura atómica de estado;
- ejecución estructurada de procesos;
- rechazo de workspaces, Nx, Yarn y pnpm.

No se modifica todavía la lista pública de comandos. `run` se publica en la fase 5, cuando pueda ejecutar la pipeline completa. Los tests de esta fase pueden importar módulos directamente.

## 3. Archivos permitidos

Modificar:

```text
scripts/modules/Migration.Project.psm1
scripts/modules/Migration.Pipeline.psm1
scripts/modules/Migration.State.psm1
schemas/manifest.schema.json
tests/smoke.ps1
README.md
```

Crear:

```text
tests/unit/Project.Tests.ps1
tests/unit/Baseline.Tests.ps1
tests/fixtures/projects/ready/
tests/fixtures/projects/missing-checks/
tests/fixtures/projects/failing-baseline/
tests/fixtures/tools/
```

No crear `Migration.Checks.psm1`. La arquitectura acordada limita los módulos: `Project` descubre y ejecuta checks, `Core` ejecuta procesos, `Pipeline` decide el orden y `State` persiste el avance.

## 4. Contrato de inspección

### 4.1 Fuente de Angular actual

No utilizar únicamente el rango de `package.json`. La versión efectiva debe salir de `package-lock.json`:

- lockfile v1: `dependencies["@angular/core"].version`;
- lockfile v2/v3: `packages["node_modules/@angular/core"].version`.

El rango declarado y la versión resuelta deben conservarse por separado:

```json
{
  "angular": {
    "declaredCoreSpec": "^7.2.0",
    "resolvedCoreVersion": "7.2.16",
    "currentMajor": 7
  }
}
```

Bloqueos obligatorios:

| Código | Condición |
| --- | --- |
| `angular_core_missing` | No existe `@angular/core` en las secciones admitidas. |
| `angular_core_not_locked` | Existe en `package.json`, pero no en el lockfile. |
| `angular_core_major_mismatch` | El rango declarado no admite la major resuelta. |
| `angular_package_major_mismatch` | Un paquete `@angular/*` de framework está en otra major. |
| `lockfile_invalid` | El lockfile no se puede leer o no tiene un layout admitido. |

No implementar un parser semver completo. Para determinar si el spec declarado representa la misma major se admiten únicamente specs simples ya soportados (`7`, `7.x`, `~7.2.0`, `^7.2.0`, `>=7.0.0` simple). Un rango compuesto, alias o unión se bloquea.

### 4.2 Git

`Get-ProjectGit` debe devolver:

```json
{
  "available": true,
  "valid": true,
  "clean": true,
  "branch": "main",
  "detached": false,
  "head": "<40 hex>",
  "repositoryRoot": "C:\\repo",
  "stateDirectoryIgnored": true,
  "identityConfigured": true,
  "dirtyFiles": [],
  "error": null
}
```

Validaciones exactas:

1. `git rev-parse --show-toplevel` termina con código 0.
2. La raíz Git coincide exactamente con la raíz del proyecto.
3. `git rev-parse HEAD` devuelve 40 caracteres hexadecimales.
4. `git symbolic-ref --quiet --short HEAD` devuelve una rama; detached HEAD se bloquea.
5. `git status --porcelain=v1 --untracked-files=all` está vacío.
6. `git check-ignore --quiet -- .angular-migration/.probe` termina con código 0.
7. `git config user.name` y `git config user.email` existen; se necesitarán para checkpoints de la fase 5.

Códigos separados:

```text
git_missing
git_repository_missing
git_root_mismatch
git_detached_head
git_dirty
git_identity_missing
migration_state_not_ignored
```

No agrupar todos los casos bajo `git_dirty`.

### 4.3 Node y npm

Conservar ejecutable y versión detectada:

```json
{
  "node": {
    "available": true,
    "executable": "C:\\Program Files\\nodejs\\node.exe",
    "version": "20.11.1"
  },
  "npm": {
    "available": true,
    "executable": "C:\\Program Files\\nodejs\\npm.cmd",
    "version": "10.2.4"
  }
}
```

Eliminar el prefijo `v` de Node al normalizar, pero conservar stdout completo en caso de error. Un ejecutable encontrado que devuelve código distinto de cero se considera no utilizable.

En esta fase no se decide todavía si la versión de Node es compatible con Angular destino; esa decisión corresponde al manifest resuelto de la fase 4.

### 4.4 Inventario del proyecto

La inspección debe incluir:

- `package.json` y `package-lock.json`;
- `angular.json` y nombres de proyectos;
- `tsconfig.json` si existe;
- configuraciones detectables de ESLint, TSLint, Karma, Jest, Cypress y builders Angular;
- todas las dependencias directas de las cuatro secciones;
- `peerDependenciesMeta` y `overrides` como políticas, no como dependencias;
- scripts npm existentes;
- package manager declarado;
- versión de lockfile.

No recorrer `node_modules` ni analizar código fuente para descubrir checks.

## 5. Contrato de check

Cada check descubierto debe tener esta forma:

```json
{
  "id": "build",
  "phase": "baseline",
  "status": "configured",
  "blocking": true,
  "executable": "npm",
  "arguments": ["run", "build", "--", "--configuration", "production"],
  "displayCommand": "npm run build -- --configuration production",
  "cwd": "C:\\repo",
  "timeoutSeconds": 900,
  "reason": null
}
```

`displayCommand` nunca se analiza ni ejecuta. Solo `executable` y `arguments` llegan a `Invoke-MigrationProcess`.

Timeouts por defecto:

| Check | Timeout |
| --- | ---: |
| `install` | 900 s |
| `dependency-tree` | 300 s |
| `typecheck` | 600 s |
| `lint` | 600 s |
| `unit-test` | 900 s |
| `build` | 1200 s |
| `e2e` | 1800 s |

No aceptar timeouts desde el agente o la línea de comandos. Las constantes viven en `Migration.Project.psm1` y solo cambian mediante código versionado.

## 6. Descubrimiento exacto de checks

Orden fijo:

```text
install
dependency-tree
typecheck
lint
unit-test
build
e2e
```

Reglas:

### install

Siempre configurado como:

```text
npm ci
```

No utilizar `npm install`, `--legacy-peer-deps`, `--force`, `--ignore-scripts` ni `--omit`.

### dependency-tree

Siempre configurado después de install:

```text
npm ls --all
```

### typecheck

Elegir el primer script existente en este orden:

```text
typecheck
type-check
check:types
tsc
```

Si no existe script, no inventar `npx tsc`. Estado `not-configured`.

### lint

Usar únicamente el script `lint`. Si no existe, `not-configured`.

### unit-test

Elegir:

```text
test:unit
unit-test
test
```

Para `test`, añadir argumentos no interactivos solo si están definidos por una política versionada y comprobada para el runner. En esta fase no añadir `--watch=false` de forma genérica, porque no todos los scripts lo aceptan.

### build

Usar únicamente `build`. Es obligatorio para un proyecto de tipo `application`. Si el script falta:

```json
{
  "status": "blocked",
  "reason": "Application project does not define an npm build script"
}
```

Para un workspace compuesto solo por librerías, `build` puede ser `not-configured`, pero los workspaces multipaquete siguen fuera de alcance.

### e2e

Elegir:

```text
e2e
test:e2e
cy:run
```

Si no existe, `not-configured`. No buscar Playwright ni crear un servidor.

## 7. Runner normalizado

Añadir a `Migration.Project.psm1`:

```powershell
function Invoke-ProjectCheck {
    param(
        [Parameter(Mandatory = $true)]$Check,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )
}

function Invoke-ProjectCheckSet {
    param(
        [Parameter(Mandatory = $true)][object[]]$Checks,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [ValidateSet('baseline', 'final')][string]$Mode
    )
}
```

`Invoke-ProjectCheck` debe:

1. rechazar checks cuyo `executable`, `arguments`, `cwd` o timeout no coincidan con el contrato descubierto;
2. devolver sin ejecutar los estados `not-configured` y `blocked`;
3. crear nombres de log a partir de `id`, nunca de input libre;
4. ejecutar mediante `Invoke-MigrationProcess`;
5. medir `startedAt`, `finishedAt` y `durationMs`;
6. escribir stdout y stderr completos en ficheros UTF-8 sin BOM;
7. devolver rutas relativas al run;
8. no incluir el contenido completo de logs en state o envelope.

Resultado:

```json
{
  "id": "build",
  "status": "passed",
  "exitCode": 0,
  "timedOut": false,
  "startedAt": "2026-09-10T10:00:00.0000000Z",
  "finishedAt": "2026-09-10T10:01:10.0000000Z",
  "durationMs": 70000,
  "stdoutLog": "logs/baseline/06-build.stdout.log",
  "stderrLog": "logs/baseline/06-build.stderr.log",
  "diagnosticSummary": null
}
```

Estados del resultado de check:

```text
passed
failed
timed-out
blocked
not-configured
```

No usar `skipped` en esta fase. Si un check anterior falla, `Invoke-ProjectCheckSet` deja de ejecutar y devuelve los checks restantes como no iniciados dentro del resultado en memoria, pero no los persiste como si hubieran sido evaluados.

## 8. Baseline

Añadir a `Migration.Pipeline.psm1`:

```powershell
function Invoke-MigrationBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$RunId
    )
}
```

Orden:

1. `Assert-ActiveRunOwnership`.
2. Leer y validar manifest y state del mismo run.
3. Exigir `status == running` y `stage == baseline`.
4. Volver a comprobar HEAD inicial y working tree limpio.
5. Ejecutar checks en el orden fijo.
6. Añadir evento `check-started` antes de cada ejecución.
7. Añadir evento `check-finished` después de cada ejecución.
8. Si todos pasan o son `not-configured`, añadir `baseline-completed`.
9. Devolver un objeto normalizado; la transición a `resolve` se integra en fase 5.

Clasificación:

| Caso | Resultado de baseline | Estado futuro del run |
| --- | --- | --- |
| Check configurado devuelve 0 | Continúa | `running` |
| Check `not-configured` | Continúa | `running` |
| Check declarado `blocked` | Se detiene | `blocked` |
| Check configurado devuelve no cero | Se detiene | `blocked` |
| Timeout | Se detiene | `blocked` |
| No se puede iniciar proceso | Se detiene | `failed` |
| No se puede escribir log/evento | Se detiene | `failed` |

Un fallo de baseline debe incluir este diagnóstico:

```json
{
  "code": "baseline_check_failed",
  "checkId": "build",
  "exitCode": 1,
  "timedOut": false,
  "stdoutLog": "logs/baseline/06-build.stdout.log",
  "stderrLog": "logs/baseline/06-build.stderr.log",
  "message": "The project does not pass its existing build before migration."
}
```

## 9. Seguridad y determinismo

- Rechazar cualquier check cuyo `cwd` no sea exactamente la raíz normalizada.
- Rechazar ejecutables con rutas procedentes de `package.json`.
- Resolver `npm.cmd` desde PATH una vez por ejecución y registrar la ruta; no aceptar otra desde el agente.
- Los nombres de scripts se eligen exclusivamente de la allowlist anterior.
- No ejecutar el valor de `scripts.<name>` directamente; `npm run <name>` es la única entrada.
- No usar `Invoke-Expression`, `cmd /c`, `powershell -Command` ni concatenación de strings de shell.
- Limitar los resúmenes de stderr almacenados en state; los logs completos permanecen en disco.
- No registrar variables de entorno, tokens, `.npmrc` ni argumentos potencialmente secretos.

## 10. Tests obligatorios

### Unitarios de Project

Cubrir:

1. lockfile v1, v2 y v3;
2. core declarado y bloqueado con misma major;
3. core declarado 7 pero bloqueado 8;
4. lockfile inválido;
5. aplicación sin build;
6. librería sin build;
7. e2e ausente;
8. prioridad de aliases de scripts;
9. check con argumentos estructurados;
10. rechazo de cwd externo;
11. timeout normalizado;
12. stdout y stderr vacíos representados como strings vacíos.

### Unitarios de baseline

Usar ejecutables fixture, nunca npm real:

1. todos los checks pasan;
2. lint ausente continúa como `not-configured`;
3. build falla y los posteriores no se ejecutan;
4. timeout produce `blocked`;
5. fallo al iniciar proceso produce `failed`;
6. un run sin ownership no ejecuta nada;
7. un state de otro run no ejecuta nada;
8. una baseline fallida no modifica `package.json` ni lockfile;
9. cada ejecución genera dos logs y dos eventos;
10. los logs no aparecen embebidos en el envelope.

### Integración mínima

Crear un fixture Git temporal con scripts `.cmd` controlados. Verificar el orden exacto:

```text
install -> dependency-tree -> typecheck -> lint -> unit-test -> build -> e2e
```

Los checks `not-configured` deben aparecer en la posición correspondiente sin ejecutar proceso.

## 11. Checklist de salida

- [ ] Angular actual procede del lockfile y no solo del rango declarado.
- [ ] Git diferencia raíz incorrecta, detached HEAD, working tree sucio e identidad ausente.
- [ ] Todos los checks tienen executable, arguments, cwd y timeout estructurados.
- [ ] Build ausente bloquea aplicaciones.
- [ ] e2e ausente es `not-configured`.
- [ ] Baseline ejecuta el orden fijo.
- [ ] Baseline rota produce `blocked`, nunca `needs-repair`.
- [ ] No existe shell libre ni interpolación ejecutable.
- [ ] Logs completos están fuera de state y stdout.
- [ ] Tests no dependen de Node, npm ni acceso a internet reales.
- [ ] No se ha publicado todavía el comando `run`.

La fase 4 no comienza hasta que todos los puntos estén demostrados por tests.
