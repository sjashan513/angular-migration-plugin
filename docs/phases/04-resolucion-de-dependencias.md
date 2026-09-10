# Fase 4 — Resolución exacta de dependencias

## 1. Resultado de la fase

Al terminar esta fase, un run que haya superado la baseline debe disponer de un `manifest.json` resuelto, completo e inmutable. Ese manifest será la única fuente de versiones para la ejecución posterior.

La fase no modifica `package.json`, `package-lock.json`, código fuente ni Git. Solo consulta metadata y publica el manifest exacto.

Resultado posible:

```text
resolved   Todas las dependencias tienen una decisión verificable.
blocked    Falta metadata, no existe combinación compatible o aparece un spec no soportado.
failed     El resolver o la persistencia han fallado internamente.
```

## 2. Archivos permitidos

Crear:

```text
scripts/modules/Migration.Dependencies.psm1
tests/unit/Dependencies.Tests.ps1
tests/integration/DependencyResolution.Tests.ps1
tests/fixtures/registry/
```

Modificar:

```text
scripts/modules/Migration.Pipeline.psm1
scripts/modules/Migration.State.psm1
scripts/angular-migration.ps1
schemas/manifest.schema.json
tests/smoke.ps1
README.md
```

No añadir módulos adicionales, clases, servicios HTTP genéricos ni una librería semver propia.

## 3. Fuente de verdad

El resolver usa exclusivamente:

1. `package.json` para intención declarada, sección y estilo de rango;
2. `package-lock.json` para versión instalada de partida;
3. registry configurado de npm mediante `npm view` para versiones y metadata publicada;
4. peer dependencies y engines publicados por los paquetes candidatos;
5. manifest del run para source/target y políticas cerradas.

No usar resultados de búsquedas web como input ejecutable. La documentación oficial puede explicar decisiones humanas, pero ninguna versión instalada procede de texto generado por un agente.

No llamar directamente a `registry.npmjs.org` mediante `Invoke-WebRequest`. `npm view` respeta `.npmrc`, registries internos y autenticación empresarial. No leer, copiar ni registrar el contenido de `.npmrc`.

## 4. API interna del módulo

Exportar únicamente:

```powershell
Get-DependencyMetadata
Resolve-MigrationManifest
Test-ResolvedManifest
Get-ResolvedManifestHash
```

Firmas:

```powershell
function Get-DependencyMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$VersionSelector,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )
}

function Resolve-MigrationManifest {
    param(
        [Parameter(Mandatory = $true)]$PendingManifest,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )
}

function Test-ResolvedManifest {
    param([Parameter(Mandatory = $true)]$Manifest)
}

function Get-ResolvedManifestHash {
    param([Parameter(Mandatory = $true)]$Manifest)
}
```

Todas las funciones reciben objetos estructurados. Ninguna acepta comandos, flags npm, URLs, tokens o ejecutables.

## 5. Ejecución de npm view

El único patrón permitido es:

```text
npm view <package>@<selector> version peerDependencies peerDependenciesMeta engines ng-update deprecated dist-tags --json
```

El controlador construye `<package>@<selector>` a partir de un nombre validado y un selector generado internamente.

Validación de nombre:

```regex
^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$
```

No interpolar el comando como string. Ejemplo conceptual:

```powershell
$arguments = @(
    'view',
    "$PackageName@$VersionSelector",
    'version',
    'peerDependencies',
    'peerDependenciesMeta',
    'engines',
    'ng-update',
    'deprecated',
    'dist-tags',
    '--json'
)
$result = Invoke-MigrationProcess `
    -FilePath $npmPath `
    -Arguments $arguments `
    -WorkingDirectory $ProjectRoot `
    -TimeoutSeconds 120
```

Cada consulta genera un evento con nombre de paquete, selector, código de salida, duración y ruta de logs. Nunca se guarda un token ni el entorno.

## 6. Cache de metadata

La misma combinación paquete/selector se consulta una sola vez por run. La cache vive en memoria durante una invocación de `run`. Para reanudación, los resultados normalizados se guardan dentro del manifest resuelto; no se crea una cache global.

Clave:

```text
lowercase(packageName) + "|" + selector
```

No compartir metadata entre proyectos o runs, porque pueden usar registries y credenciales distintos.

## 7. Clasificación de dependencias

Procesar todas las entradas directas de:

```text
dependencies
devDependencies
optionalDependencies
peerDependencies
```

Conservar `peerDependenciesMeta` y `overrides` como políticas separadas.

Clasificaciones:

| Grupo | Ejemplos | Política |
| --- | --- | --- |
| Angular framework | `@angular/core`, `common`, `compiler`, `forms`, `router`, `animations`, `platform-*` | Major objetivo; resolver última estable compatible. |
| Angular tooling | `@angular/cli`, `@angular/compiler-cli`, `@angular-devkit/*`, `@ngtools/*` | Resolver conjunto compatible con framework objetivo. |
| Toolchain relacionado | `typescript`, `rxjs`, `zone.js` | Resolver dentro de los peers publicados por Angular objetivo. |
| Angular-aware externo | Paquete cuyo peer declara `@angular/core`, `common` o `compiler` | Mantener major si existe candidato compatible; subir a la major mínima compatible si es necesario. |
| Registry ordinario | Resto de paquetes registry | Última estable dentro de su major instalada actual. |
| No soportado | alias, Git, URL, local, workspace, patch | `blocked`; no modificar. |

Un paquete no puede cambiar de sección. Si aparece en varias secciones, bloquear con `duplicate_dependency_declaration` salvo que npm defina explícitamente una combinación admitida y exista un test para ella.

## 8. Definición de versión estable

Una versión candidata es estable si:

- cumple `MAJOR.MINOR.PATCH`;
- no contiene prerelease (`-next`, `-rc`, `-beta`, etc.);
- no está marcada `deprecated`;
- aparece en la respuesta del registry;
- satisface los peers obligatorios conocidos.

No usar `latest` como versión persistida. `latest` puede utilizarse como selector de consulta auxiliar, pero el manifest siempre contiene una versión exacta.

## 9. Algoritmo exacto de resolución

### Paso 1 — Validar input

Rechazar si:

- `resolutionStatus` no es `pending`;
- el manifest no pertenece al run activo;
- `targetMajor != sourceMajor + 1`;
- falta versión bloqueada actual de cualquier dependencia directa;
- aparece un spec no registry;
- falta baseline passed;
- el manifest ya tiene `manifestSha256`.

### Paso 2 — Resolver Angular framework

Para cada paquete framework instalado:

1. consultar versiones de la major objetivo;
2. filtrar prereleases y deprecated;
3. ordenar descendente por major, minor, patch;
4. elegir la mayor exacta;
5. comprobar que todos los paquetes framework seleccionados comparten major objetivo;
6. conservar pares de peers que deban evaluarse después.

`@angular/core` y `@angular/common` deben quedar en la misma versión exacta. `@angular/compiler` debe alinearse con core si está instalado. Si el registry no ofrece una combinación alineada, `angular_framework_unresolvable`.

### Paso 3 — Resolver CLI y tooling

1. seleccionar la última versión estable de `@angular/cli` dentro de target major;
2. seleccionar `@angular/compiler-cli` compatible con framework y TypeScript;
3. resolver cada `@angular-devkit/*` o `@ngtools/*` instalado según los peers/dependencias publicados por la CLI candidata;
4. no instalar tooling que no existía salvo `@angular/compiler-cli` si el proyecto Angular lo requiere y falta; ese caso debe quedar marcado como `added-required-tooling`.

### Paso 4 — Resolver TypeScript, RxJS y Zone.js

Construir restricciones desde metadata:

- TypeScript: peers de `@angular/compiler-cli` y paquetes tooling;
- RxJS: peer de `@angular/core` y de librerías Angular-aware;
- Zone.js: peer de `@angular/core` si existe;
- Node: intersección de `engines.node` de CLI, compiler-cli y tooling seleccionado.

Para cada paquete:

1. intentar la última estable dentro de la major actualmente instalada que satisfaga todas las restricciones;
2. si no existe, elegir la versión estable mínima en la major más baja que satisfaga la intersección;
3. registrar por qué fue necesario cambiar de major;
4. bloquear si no existe candidato.

No actualizar Node automáticamente. El manifest registra el rango requerido y compara la versión activa. Si Node no satisface la intersección:

```text
blocked / node_version_incompatible
```

El diagnóstico incluye rango requerido, versión activa y paquetes que originaron la restricción.

### Paso 5 — Resolver paquetes Angular-aware externos

Para cada paquete cuyo candidato actual o publicado declare peer sobre Angular:

1. buscar primero en la major instalada actual;
2. elegir la última estable cuyo peer admita target Angular;
3. si ninguna sirve, recorrer majors superiores en orden ascendente;
4. elegir la primera major con un candidato compatible y, dentro de ella, la última estable;
5. bloquear si no existe candidato compatible;
6. registrar el cambio de major y peer que lo exigió.

No sustituir automáticamente una librería por otra.

### Paso 6 — Resolver dependencias ordinarias

Para cada dependencia registry restante:

1. obtener major instalada desde lockfile;
2. consultar la última versión estable dentro de esa major;
3. conservar major;
4. evaluar peers declarados por el candidato contra el conjunto final;
5. si hay conflicto, bloquear; no cambiar de major sin una dependencia demostrable con Angular objetivo.

Esta regla cumple el acuerdo de actualizar todas las dependencias sin introducir majors arbitrarias.

### Paso 7 — Validar conjunto completo

Repetir hasta punto fijo, con máximo de diez iteraciones:

1. construir mapa `package -> targetVersion`;
2. revisar todos los peers obligatorios;
3. si un peer no está presente y el paquete lo declara opcional, registrar warning;
4. si es obligatorio y falta, bloquear;
5. si está presente pero no satisface el rango, intentar el siguiente candidato permitido para el paquete dependiente;
6. si ninguna sustitución converge, bloquear con grafo de conflicto.

No continuar después de diez iteraciones. Código: `dependency_resolution_did_not_converge`.

## 10. Estilo de escritura para package.json

El manifest guarda dos valores:

```json
{
  "targetVersion": "8.2.14",
  "writeSpec": "^8.2.14"
}
```

Reglas de `writeSpec`:

| Spec original | Escribir |
| --- | --- |
| `7.2.0` | `8.2.14` |
| `^7.2.0` | `^8.2.14` |
| `~7.2.0` | `~8.2.14` |
| `>=7.2.0` | `>=8.2.14` solo si el parser actual lo soporta de forma inequívoca; en caso contrario bloquear. |
| `7.x` o `7.*` | `8.x` o `8.*` conservando el estilo. |

Para dependencias ordinarias que mantienen major, aplicar la misma regla sustituyendo la versión exacta resuelta.

## 11. Manifest resuelto

Forma mínima por dependencia:

```json
{
  "name": "@angular/core",
  "section": "dependencies",
  "role": "angular-framework",
  "kind": "registry",
  "declaredSpec": "^7.2.0",
  "currentVersion": "7.2.16",
  "targetVersion": "8.2.14",
  "writeSpec": "^8.2.14",
  "change": "major-required",
  "reason": "Angular framework packages align to target major 8",
  "metadata": {
    "source": "npm-view",
    "selector": "^8.0.0",
    "retrievedAt": "2026-09-10T10:00:00.0000000Z",
    "deprecated": false,
    "peerDependencies": {},
    "engines": {},
    "ngUpdate": null
  }
}
```

Raíz del manifest:

```json
{
  "schemaVersion": 5,
  "manifestType": "migration",
  "runId": "angular-7-to-8-...",
  "sourceMajor": 7,
  "targetMajor": 8,
  "resolutionStatus": "resolved",
  "resolverVersion": 1,
  "resolvedAt": "2026-09-10T10:00:00.0000000Z",
  "node": {
    "activeVersion": "20.11.1",
    "requiredRange": ">=10.9.0",
    "compatible": true
  },
  "dependencies": [],
  "warnings": [],
  "manifestSha256": "<64 hex>"
}
```

`manifestSha256` se calcula sobre el JSON canónico sin el propio campo hash:

1. claves de objetos ordenadas ordinalmente;
2. arrays en su orden contractual;
3. UTF-8 sin BOM;
4. sin whitespace insignificante;
5. SHA-256 en minúsculas.

Implementar una única función de serialización canónica. No usar directamente el orden accidental de `ConvertTo-Json` para el hash.

## 12. Publicación e inmutabilidad

La publicación debe:

1. resolver por completo en memoria;
2. validar schema;
3. calcular hash;
4. escribir `manifest.json` atómicamente;
5. releerlo;
6. recalcular hash;
7. guardar `manifestSha256` en state mediante ownership;
8. añadir `manifest-resolved` a events.

Después de `state.manifestSha256` no se permite volver a escribir `manifest.json`. Toda lectura posterior compara el hash. Un mismatch produce:

```text
failed / manifest_integrity_failed
```

No intentar reparar automáticamente un manifest alterado.

La propiedad publicada por npm `ng-update` se normaliza como `metadata.ngUpdate`.
Debe conservarse completa, sin interpretarla durante esta fase. La fase 5 utilizará
esa copia para localizar colecciones de migración; no realizará una segunda consulta
al registry ni permitirá que un agente invente el nombre de una colección.

## 13. Errores y warnings

Bloqueos mínimos:

```text
unsupported_dependency_spec
dependency_not_locked
registry_metadata_unavailable
registry_metadata_invalid
angular_framework_unresolvable
toolchain_unresolvable
node_version_incompatible
peer_dependency_conflict
dependency_resolution_did_not_converge
duplicate_dependency_declaration
manifest_already_resolved
```

Warnings permitidos:

```text
optional_peer_missing
package_deprecation_ignored_candidate
package_major_changed_for_angular
metadata_field_missing_noncritical
```

Un warning nunca sustituye un dato necesario para demostrar compatibilidad.

## 14. Tests obligatorios

El test no consulta internet. `tests/fixtures/registry/` contiene respuestas JSON normalizadas de `npm view` y un ejecutable npm fixture las devuelve según argumentos exactos.

Cubrir:

1. Angular 7 -> 8 con core/common/compiler/cli;
2. alineación de todos los `@angular/*` instalados;
3. TypeScript obligado a cambiar minor o major;
4. RxJS mantiene major cuando es compatible;
5. paquete Angular-aware mantiene major;
6. paquete Angular-aware necesita major superior;
7. paquete Angular-aware sin candidato compatible;
8. dependencia ordinaria actualiza minor/patch pero no major;
9. prerelease excluida;
10. versión deprecated excluida;
11. peer opcional ausente genera warning;
12. peer obligatorio ausente bloquea;
13. Node incompatible bloquea;
14. metadata privada inaccesible bloquea sin filtrar credenciales;
15. manifest incluye cada dependencia directa exactamente una vez;
16. se conserva la sección original;
17. se conserva estilo `^`, `~`, exacto y `x`;
18. hash estable con distinto orden de propiedades de entrada;
19. alteración posterior del manifest produce integridad fallida;
20. segundo intento de resolver un manifest resuelto se rechaza;
21. no aparece ningún flag prohibido en argumentos;
22. timeout de registry se clasifica como `blocked`, no `failed`, si npm se ejecutó correctamente pero no obtuvo metadata.
23. `ng-update` publicado se conserva como `metadata.ngUpdate` sin pérdida de campos.

## 15. Checklist de salida

- [ ] Existe exactamente un nuevo módulo: `Migration.Dependencies.psm1`.
- [ ] Todas las dependencias directas aparecen en el manifest.
- [ ] Cada target es una versión exacta estable.
- [ ] El manifest conserva sección y writeSpec.
- [ ] Angular, tooling, TypeScript, RxJS y Zone forman un conjunto compatible.
- [ ] Dependencias ordinarias no cambian de major.
- [ ] Paquetes Angular-aware solo cambian major por necesidad demostrada.
- [ ] Node incompatible bloquea antes de modificar el proyecto.
- [ ] Metadata incompleta crítica bloquea.
- [ ] El manifest tiene hash canónico verificado.
- [ ] El manifest resuelto es inmutable.
- [ ] Tests funcionan sin registry real.
- [ ] La fase no modifica package.json, lockfile, código ni Git.

La fase 5 no comienza hasta que un fixture Angular 7 -> 8 produzca un manifest completo y estable en dos ejecuciones independientes.
