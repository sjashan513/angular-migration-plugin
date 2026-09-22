# Cambios del plugin de migración Angular y estado production ready

## 1. Contexto

Este documento resume los cambios realizados durante la migración Angular 9 →
Angular 10 y las mejoras aplicadas al plugin local
`angular-migration`. El plugin controla la resolución de versiones, los
checkpoints, las reparaciones, la instalación, la validación y la
documentación de cada run.

La migración analizada terminó con:

- `migrationStatus: verified`;
- gates críticos de instalación, dependency-tree y build superados;
- lint, unit-test y E2E omitidos mediante una decisión auditada;
- documentación research y publish registrada;
- estado final del run: `completed`.

Los cambios del plugin viven en la instalación de Copilot, no en este
repositorio. Las rutas funcionales son:

- `scripts/angular-migration.ps1`;
- `scripts/modules/Migration.Pipeline.psm1`;
- `scripts/modules/Migration.Dependencies.psm1`;
- `scripts/js/render-package-json.js`;
- schemas, README y agentes del plugin.

## 2. Cambios realizados y motivo

### 2.1 Separación de registry público y privado

El resolver pasó a consultar `https://registry.npmjs.org/` para paquetes
públicos y a conservar Nexus únicamente para paquetes `@ips/*`.

**Motivo:** el plugin intentaba resolver paquetes públicos mediante Nexus y
recibía errores `E404`. Además, un tarball de `ag-grid-community@20.2.0`
obtenido desde Nexus no contenía
`dist/lib/widgets/tooltipManager.js`, aunque el tarball oficial sí lo incluye.

En el proyecto, `.npmrc` quedó alineado con esa política:

- registry por defecto: npm público;
- scope `@ips`: registry privado.

No deben almacenarse credenciales de Nexus en un fichero versionado. La
configuración production ready debe inyectar autenticación mediante variables
de entorno, configuración del runner o un secret store.

### 2.2 Resolución coordinada de Angular y DevKit

El resolver distingue entre:

- paquetes Angular framework;
- CLI y DevKit con versiones `10.x`;
- paquetes DevKit que utilizan formato `0.1002.x`;
- dependencias públicas ordinarias;
- excepciones privadas declaradas por el proyecto.

**Motivo:** tratar todos los paquetes como si siguieran el mismo esquema de
versionado producía selecciones incorrectas para `@angular-devkit/architect` y
`@angular-devkit/build-angular`.

### 2.3 Excepciones de peers y promociones explícitas

Se incorporaron políticas de run para:

- la incompatibilidad conocida de peers de `@ips/ionic@0.4.0`;
- la promoción de `tslib`;
- la promoción de `core-js`.

Las excepciones no son globales: identifican paquete, versión, peers
ignorados, motivo y scope.

**Motivo:** npm moderno rechazaba el árbol por peers Angular 9 declarados por
un paquete interno que debía seguir instalado durante la migración. El plugin
ahora acepta únicamente el mismatch configurado, no cualquier peer inválido.

### 2.4 Reparaciones auditadas y recuperación

El pipeline ahora:

- normaliza evidencias completas y relativas (`logs/...`);
- valida las rutas contra el run activo;
- conserva historial append-only por fingerprint;
- distingue `submission-accepted` de `verification-passed`;
- permite `override-repair` únicamente con motivo y confirmación explícita;
- conserva intentos rechazados y fallidos;
- reconcilia commit, informe, state y events después de una interrupción.

**Motivo:** el run se bloqueaba aunque la reparación estaba correctamente
aceptada o aunque el agente entregaba evidencias equivalentes pero con una
ruta no canónica. El override evita esperar indefinidamente sin borrar la
traza de auditoría.

### 2.5 Envelope único y estados fiables

La fachada normaliza la salida para que cada operación produzca un único
envelope con `status`, `data` y `error`. También se corrigió la lectura de
resultados que no tenían obligatoriamente una propiedad `status`.

**Motivo:** texto adicional de PowerShell o resultados parciales provocaban
errores de envelope y el controlador perdía el estado real del run.

### 2.6 Dependencias y peers durante la instalación

Se corrigieron tres puntos relacionados:

1. Las promociones transitorias se consideran durante la prevalidación aunque
   todavía no estén en `package.json`.
2. El renderer puede materializar esas promociones en el manifiesto.
3. `npm install --package-lock-only` y `npm ci` usan
   `--legacy-peer-deps` únicamente cuando existe una excepción explícita.

La validación de `npm ls --all` acepta solo los peers inválidos cubiertos por
esa excepción.

**Motivo:** el renderer bloqueaba antes de escribir dependencias necesarias y
npm 7+ rechazaba una incompatibilidad intencionada aunque estuviera
documentada.

### 2.7 Checks omitidos preservados

Los checks omitidos en baseline se conservan durante `validate` y aparecen
como `status: skipped`. En particular, no se vuelven a ejecutar lint,
unit-test o E2E por accidente.

**Motivo:** el pipeline ignoraba la decisión auditada de skip y repetía lint
durante la validación final. Los gates `install`, `dependency-tree` y `build`
siguen siendo obligatorios.

### 2.8 Reparaciones específicas de Angular 10

El pipeline añadió recuperación controlada para:

- eliminar `es5BrowserSupport`, opción obsoleta en Angular 10;
- seleccionar distribuciones TypeScript compatibles, como la tag `ts3.9` de
  `@types/leaflet`;
- materializar dependencias y lockfile después de una recuperación validada.

Las reparaciones de código de la aplicación se mantuvieron limitadas a los
paths autorizados por cada contexto.

### 2.9 Documentación verificable

El documenter trabaja en dos fases:

- research antes de `verified`;
- publish después de `verified`.

El controlador valida hashes, fuentes, claims, evidencias, enlaces, conjunto
exacto de ocho documentos y commit técnico antes de registrar la publicación.

**Motivo:** separar la escritura del agente de la mutación de `state.json`
evita carreras y permite auditar qué evidencia respaldaba cada afirmación.

## 3. Cambio específico del hook de AG Grid

Este cambio pertenece al proyecto, no al plugin de migración Angular.

El hook original copiaba siempre un `tooltipManager.js` generado para
AG Grid 20.1.0 sobre cualquier versión instalada. Ese archivo importaba
`componentRecipes`, que no existe en la implementación 20.2.0. El resultado
era:

```text
Module not found: Can't resolve '../components/framework/componentRecipes'
```

La implementación actual de
`scripts/ag-grid-tooltip-hook/copy_tooltipManager.js`:

1. detecta la versión instalada;
2. localiza el `tooltipManager.js` del propio paquete;
3. cambia únicamente `MOUSEOVER_SHOW_TOOLTIP_TIMEOUT` a `200`;
4. no copia código interno de otra versión;
5. falla explícitamente si cambia la ruta o desaparece el símbolo esperado.

También se eliminó el fichero estático antiguo
`scripts/ag-grid-tooltip-hook/tooltipManager.js`.

El objetivo funcional se conserva: los tooltips de AG Grid aparecen a los
200 ms en vez de esperar 2 segundos. El hook sigue siendo un parche sobre
código interno; por eso debe retirarse cuando la versión de AG Grid exponga
una opción pública equivalente.

## 4. Estado actual frente a production ready

El plugin es funcional y auditable para el perímetro documentado, pero todavía
no debe considerarse production ready sin completar estos puntos.

### P0 — Bloqueantes

1. **Eliminar secretos del repositorio**
   - sacar credenciales de `.npmrc`;
   - rotar cualquier credencial que haya estado versionada;
   - usar variables de entorno o secret store;
   - impedir que logs, errores y artefactos impriman tokens o cabeceras.

2. **Pruebas de instalación reproducible**
   - probar desde un checkout limpio;
   - validar npm 6, 7 y la versión soportada por cada lockfile;
   - comprobar que paquetes públicos nunca dependan de un mirror privado;
   - verificar integridad SHA-512 y procedencia del tarball;
   - probar registry inaccesible, paquete ausente, `E404` y timeout.

3. **Matriz real de compatibilidad**
   - fijar oficialmente versiones soportadas de Windows, PowerShell, Node,
     npm, fnm, Angular CLI y lockfile;
   - ejecutar fixtures para Angular 7, 8, 9 y 10;
   - probar proyectos con dependencias privadas y sin dependencias privadas;
   - rechazar claramente monorepos, workspaces, Yarn y pnpm si siguen fuera de
     alcance.

### P1 — Fiabilidad y seguridad

1. **Suite de contratos**
   - validar todos los schemas con fixtures válidos e inválidos;
   - probar envelopes con stdout adicional, JSON corrupto y errores parciales;
   - probar secuencias de estado imposibles y transiciones repetidas.

2. **Recuperación y concurrencia**
   - probar dos procesos sobre el mismo run;
   - probar locks huérfanos, proceso terminado y proceso vivo;
   - probar interrupción durante commit, escritura de state y append de events;
   - usar escrituras temporales y reemplazo atómico para `state.json`,
     `result.json` y documentos.

3. **Subprocesos y ejecución**
   - centralizar timeouts, cancelación y códigos de salida;
   - eliminar cualquier captura amplia que convierta un fallo en éxito;
   - registrar stdout/stderr con límites de tamaño y redacción;
   - validar que ninguna entrada del usuario o agente pueda convertirse en
     argumentos arbitrarios de PowerShell, npm o Git.

4. **Lockfile y registry**
   - no editar URLs de tarballs como parche manual en cada proyecto;
   - generar y verificar el lockfile desde una política de registry explícita;
   - comprobar que el hostname de cada paquete coincide con su scope;
   - impedir fallback silencioso de público a privado o viceversa.

5. **Reparaciones de agentes**
   - aplicar allowlists de paths también en la capa de escritura;
   - verificar que el diff solo contiene los paths del contexto;
   - limitar tamaño, número y duración de entregas;
   - validar hash de cada entrada JSONL y detenerse ante corrupción.

### P2 — Operación y mantenimiento

1. **Observabilidad**
   - emitir un correlation ID por run;
   - medir duración por stage, reintentos y motivos de bloqueo;
   - separar eventos operativos de datos de usuario;
   - ofrecer un resumen seguro para CI sin exponer el contenido completo de
     logs.

2. **Política de retención**
   - definir cuánto tiempo se conservan logs, repairs y documentos;
   - incluir una operación de archive/export verificable;
   - documentar quién puede leer o eliminar artefactos.

3. **Versionado del contrato**
   - versionar schemas y `ResolverVersion`;
   - mantener migraciones de artefactos antiguos;
   - publicar changelog del plugin;
   - añadir pruebas de compatibilidad hacia atrás para runs en curso.

4. **CI/CD**
   - ejecutar lint, tests del plugin, análisis estático y fixtures en cada
     cambio;
   - probar una migración sintética completa sin depender de un proyecto
     productivo;
   - exigir revisión para cambios en registry, ejecución de comandos,
     permisos, locks y recuperación.

## 5. Recomendación de prioridad

El orden recomendado es:

1. retirar y rotar credenciales;
2. validar instalación limpia y procedencia de paquetes;
3. crear fixtures de contratos, locks y recuperación;
4. endurecer subprocesos, logs y allowlists;
5. formalizar la matriz de versiones soportadas;
6. añadir observabilidad, retención y CI/CD.

Hasta completar los P0, el plugin debe considerarse **apto para migraciones
controladas y auditadas**, pero no como herramienta de producción sin
supervisión.

## 6. Validación realizada en este cambio

Se verificó:

- sintaxis de `copy_tooltipManager.js`;
- sintaxis del `tooltipManager.js` instalado;
- ejecución del hook sobre AG Grid 20.2.0;
- uso de `userComponentFactory`, la dependencia correcta de 20.2.0;
- retardo final de 200 ms;
- routing público de npm y routing privado de `@ips`.

No se ejecutó el build completo ni se reactivaron los checks de lint,
unit-test o E2E.
