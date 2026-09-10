# Fase 7 — Agente de investigación y documentación

## 1. Resultado de la fase

Esta fase añade `migration-documenter`, un agente sin capacidad de ejecutar comandos y
sin permiso para modificar código. Su responsabilidad es explicar, con evidencia, qué
cambió entre la major origen y la major objetivo, qué errores aparecieron, cómo se
repararon, qué warnings permanecen y qué conceptos nuevos debe conocer el equipo.

El agente tiene dos invocaciones independientes:

```text
manifest resuelto -> research -> research.json
migración verified + research.json -> publish -> docs/migration/v<target>/
```

La primera puede ejecutarse en paralelo con la migración. La segunda solo comienza
cuando `migrationStatus=verified`. Investigar en paralelo nunca autoriza publicar como
hecho algo que aún no ocurrió en el repositorio.

## 2. Archivos permitidos

Crear:

```text
agents/migration-documenter.agent.md
schemas/documentation-context.schema.json
schemas/documentation-research.schema.json
schemas/documentation-input.schema.json
tests/unit/DocumentationContract.Tests.ps1
tests/integration/DocumentationCycle.Tests.ps1
tests/fixtures/documentation/
```

Modificar:

```text
scripts/angular-migration.ps1
scripts/modules/Migration.Pipeline.psm1
scripts/modules/Migration.State.psm1
scripts/hooks/copilot-policy.ps1
hooks.json
tests/smoke.ps1
README.md
```

No crear un generador Markdown genérico ni un tercer agente. Las plantillas y
validaciones pertenecen a esta fase.

## 3. Comandos públicos

Añadir exactamente:

```powershell
./scripts/angular-migration.ps1 documentation-context -RunId <run-id> -Mode research
./scripts/angular-migration.ps1 documentation-context -RunId <run-id> -Mode publish
./scripts/angular-migration.ps1 record-documentation -RunId <run-id> -Mode research -InputFile <path>
./scripts/angular-migration.ps1 record-documentation -RunId <run-id> -Mode publish -InputFile <path>
```

Rutas aceptadas:

```text
research -> .angular-migration/runs/<run-id>/inbox/research.json
publish  -> .angular-migration/runs/<run-id>/inbox/documentation.json
```

Resolver y validar la ruta final con las mismas reglas de la fase 6. Ningún comando
acepta una carpeta de salida proporcionada por el agente.

## 4. Estados de documentación

Añadir a state:

```json
{
  "documentation": {
    "status": "not-started",
    "researchSha256": null,
    "researchCommit": null,
    "publishAttempt": 0,
    "publishedCommit": null,
    "completedAt": null,
    "lastError": null
  }
}
```

Valores válidos:

```text
not-started -> researching -> researched -> publishing -> completed
                                 |              |
                              failed          failed
```

`failed` conserva `phase: research|publish` y permite reintento. Un fallo documental
no cambia una migración técnica `verified` a `failed`, pero el run no llega a
`completed` y conserva el lock hasta una publicación válida o una intervención manual.

## 5. Contexto research

Se permite cuando el manifest está resuelto y su hash coincide, incluso si la pipeline
técnica sigue ejecutándose. Forma exacta:

```json
{
  "schemaVersion": 1,
  "mode": "research",
  "runId": "angular-7-to-8-20260910T100000Z-a1b2c3d4",
  "sourceMajor": 7,
  "targetMajor": 8,
  "manifestSha256": "<64-hex>",
  "dependencies": [
    {
      "name": "@angular/core",
      "currentVersion": "7.2.16",
      "targetVersion": "8.2.14",
      "change": "major-required",
      "reason": "Angular framework packages align to target major 8"
    }
  ],
  "questions": [
    "¿Qué breaking changes oficiales aplican de Angular 7 a 8?",
    "¿Qué migraciones automáticas declara cada paquete actualizado?",
    "¿Qué conceptos nuevos afectan al mantenimiento del proyecto?",
    "¿Qué warnings/deprecations oficiales pueden aparecer?"
  ],
  "allowedWritePath": ".angular-migration/runs/<run-id>/inbox/research.json"
}
```

La lista de dependencias procede del manifest inmutable. El agente no puede añadir una
dependencia que no exista allí ni cambiar versiones.

## 6. Fuentes de investigación

Orden obligatorio:

1. Angular Update Guide oficial;
2. changelog y guías oficiales del repositorio Angular;
3. documentación oficial de Angular;
4. changelog/release notes del repositorio oficial del paquete;
5. metadata publicada por npm ya conservada en manifest;
6. issue oficial únicamente para explicar un error concreto no cubierto arriba.

Blogs, Stack Overflow, Reddit y contenido generado por IA no son fuente normativa. Se
pueden incluir como lectura secundaria solo si la afirmación también está sustentada por
una fuente primaria. No copiar bloques largos; resumir y enlazar.

Cada afirmación debe diferenciar:

```text
official-change  La fuente afirma que cambió.
observed-change  El diff o evento del run demuestra que ocurrió aquí.
inference        Conclusión razonada; debe etiquetarse explícitamente.
not-applicable   Cambio oficial revisado que no aplica al proyecto.
```

Usar fecha UTC ISO-8601 de consulta. Rechazar URLs con query secrets, anchors de sesión,
localhost, file URLs o esquemas distintos de HTTPS.

## 7. research.json

Schema mínimo y cerrado:

```json
{
  "schemaVersion": 1,
  "runId": "angular-7-to-8-20260910T100000Z-a1b2c3d4",
  "sourceMajor": 7,
  "targetMajor": 8,
  "manifestSha256": "<64-hex>",
  "researchedAt": "2026-09-10T10:30:00.0000000Z",
  "sources": [
    {
      "id": "angular-update-guide-7-8",
      "title": "Angular Update Guide",
      "url": "https://angular.dev/update-guide",
      "publisher": "Angular",
      "primary": true,
      "accessedAt": "2026-09-10T10:20:00.0000000Z"
    }
  ],
  "findings": [
    {
      "id": "F-001",
      "kind": "official-change",
      "area": "framework",
      "title": "Título breve",
      "summary": "Paráfrasis concreta del cambio.",
      "affectedPackages": ["@angular/core"],
      "sourceIds": ["angular-update-guide-7-8"],
      "applicability": "unknown-until-verified"
    }
  ],
  "concepts": [
    {
      "id": "C-001",
      "name": "Nombre del concepto",
      "whyItMatters": "Relación con el salto 7 a 8.",
      "sourceIds": ["angular-update-guide-7-8"]
    }
  ],
  "unresolved": []
}
```

Validaciones de `record-documentation -Mode research`:

- run, majors y manifest hash exactos;
- al menos una fuente primaria para cada `official-change`;
- todos los `sourceIds` existen y no se repiten;
- paquetes afectados pertenecen al manifest;
- no hay fragmentos de código ejecutable, comandos de migración ni versiones nuevas;
- cada texto tiene límites: title 160, summary 2000, whyItMatters 2000 caracteres;
- el archivo se mueve a `artifacts/research.json`, se calcula hash y se registra evento;
- no se crea commit de código ni se toca `docs/` durante research.

El agente puede declarar `unresolved`; inventar una respuesta está prohibido. Un
`unresolved` crítico no impide la migración, pero bloquea la publicación final hasta que
se resuelva o se marque explícitamente `not-applicable` con evidencia.

## 8. Contexto publish

Solo se emite con:

```text
migrationStatus = verified
documentation.status = researched
manifest hash válido
result.json válido
HEAD = technicalVerifiedCommit
```

Debe incluir:

```json
{
  "schemaVersion": 1,
  "mode": "publish",
  "runId": "<run-id>",
  "sourceMajor": 7,
  "targetMajor": 8,
  "manifestSha256": "<64-hex>",
  "researchSha256": "<64-hex>",
  "technicalVerifiedCommit": "<40-hex>",
  "outputDirectory": "docs/migration/v8",
  "requiredFiles": [
    "README.md",
    "changes.md",
    "errors-and-repairs.md",
    "warnings.md",
    "new-concepts.md",
    "dependencies.md",
    "validation.md",
    "sources.md"
  ],
  "evidence": {
    "manifest": ".angular-migration/runs/<run-id>/manifest.json",
    "result": ".angular-migration/runs/<run-id>/result.json",
    "research": ".angular-migration/runs/<run-id>/artifacts/research.json",
    "events": ".angular-migration/runs/<run-id>/events.jsonl",
    "repairs": ".angular-migration/runs/<run-id>/repairs"
  },
  "submissionPath": ".angular-migration/runs/<run-id>/inbox/documentation.json"
}
```

El agente puede leer el diff entre el commit de inicio y `technicalVerifiedCommit`, pero
no puede escribir hasta que el hook confirme que la ruta está bajo `outputDirectory`.

## 9. Documentos finales y plantillas

Crear exactamente ocho archivos. No condensarlos en uno ni crear variantes.

### `README.md`

```markdown
# Migración Angular <source> → <target>

## Resumen
Estado técnico, fecha, run id y commits de inicio/final.

## Alcance
Qué paquetes y áreas se actualizaron.

## Resultado
Qué gates pasaron y si quedan warnings.

## Navegación
Enlaces relativos a los otros siete documentos.
```

### `changes.md`

```markdown
# Cambios aplicados

## Cambios automáticos de Angular
Para cada cambio: archivo, descripción, evento/commit y fuente oficial.

## Cambios manuales
Para cada reparación: error original, causa, modificación mínima y gate que la validó.

## Cambios oficiales no aplicables
Cambio, motivo de no aplicabilidad y evidencia del proyecto.
```

No presentar todo el changelog de Angular; solo cambios oficiales relevantes y cambios
observados en este repo.

### `errors-and-repairs.md`

Una sección por fingerprint:

```markdown
## <check> — <resumen>

- Fingerprint: `<valor>`
- Etapa e intento: `<stage>`, `<n>`
- Error observado: explicación y enlace relativo al log
- Causa raíz: explicación sustentada
- Archivos modificados: lista exacta
- Reparación: qué se hizo y por qué
- Verificación: gate, exit code y evento que demuestra el resultado
```

Si no hubo reparaciones, escribir: “La ejecución no requirió reparaciones manuales”.

### `warnings.md`

Clasificar cada warning como `resolved`, `accepted` o `action-required`. Incluir origen,
impacto, decisión y evidencia. Un warning deprecado no se describe como error. Si no hay
warnings: “No quedaron warnings registrados por la pipeline”.

### `new-concepts.md`

Explicar cada concepto con esta estructura:

```markdown
## <concepto>

### Explicación intuitiva
### Qué cambió entre las versiones
### Cómo aparece en este proyecto
### Qué debe hacer el equipo a partir de ahora
### Fuente oficial
```

No incluir conceptos genéricos sin relación demostrada con manifest, diff o resultado.

### `dependencies.md`

Tabla construida exclusivamente desde manifest:

```markdown
| Paquete | Sección | Antes | Después | Tipo de cambio | Motivo |
| --- | --- | ---: | ---: | --- | --- |
```

Incluir todas las dependencias directas, incluso las que no cambiaron. Añadir secciones
para cambios de major, constraints de peers, Node requerido y paquetes deprecated.

### `validation.md`

Para cada gate: comando lógico (no secretos), estado, duración, exit code y rutas de
logs. Incluir hashes de manifest/result y commits. No afirmar pruebas que no estén en
`result.json`.

### `sources.md`

Lista numerada de fuentes con publisher, título, URL HTTPS, fecha de consulta y findings
que sustenta. Separar fuentes primarias de secundarias. Toda fuente citada en otro
documento debe existir aquí.

## 10. documentation.json

Después de escribir los ocho archivos, el agente entrega:

```json
{
  "schemaVersion": 1,
  "runId": "<run-id>",
  "mode": "publish",
  "manifestSha256": "<64-hex>",
  "researchSha256": "<64-hex>",
  "technicalVerifiedCommit": "<40-hex>",
  "outputDirectory": "docs/migration/v8",
  "files": [
    {"path": "docs/migration/v8/README.md", "sha256": "<64-hex>"}
  ],
  "claims": [
    {
      "id": "D-001",
      "kind": "observed-change",
      "document": "changes.md",
      "evidence": ["event:<event-id>", "commit:<40-hex>", "source:F-001"]
    }
  ],
  "remainingWarnings": []
}
```

`files` contiene exactamente los ocho archivos, ordenados por nombre ordinal.

## 11. Validación y cierre

`record-documentation -Mode publish` comprueba:

1. state y ownership;
2. hashes de manifest, research y result;
3. HEAD todavía igual al commit técnico;
4. solo existen cambios bajo `docs/migration/v<target>/` y el inbox;
5. están los ocho nombres exactos, sin symlinks ni archivos extra;
6. hashes declarados coinciden con disco;
7. todos los paquetes/versiones coinciden con manifest;
8. fingerprints, gates, exit codes y commits citados existen en evidencia;
9. todo claim tiene evidencia del tipo correcto;
10. enlaces internos son relativos y apuntan a archivos existentes;
11. URLs son HTTPS y cada fuente citada existe en `sources.md`;
12. no hay tokens, rutas de usuario, `.npmrc`, variables secretas o logs completos;
13. no hay frases de éxito técnico sin evidencia de result;
14. no cambió código, configuración, package files ni Git metadata.

Si pasa, crea un commit:

```text
docs(angular-migration): document Angular <source> to <target>
```

Después registra `documentation-published`, cambia documentation a `completed`, el run
a `completed`, escribe `completedAt` y libera el lock. Si falla, revierte solo el árbol
documental creado por el intento, conserva migración `verified` y registra el motivo.

## 12. Definición del agente

Crear `agents/migration-documenter.agent.md`:

```yaml
---
name: migration-documenter
description: Investiga y documenta una migración Angular v5 usando únicamente evidencia del run y fuentes primarias.
tools: [read, search, web, edit]
user-invocable: false
disable-model-invocation: true
---
```

Contenido normativo:

```markdown
Eres el documentador de Angular Migration v5. No implementas ni corriges código.

Trabaja únicamente en el modo indicado por documentation-context. En research, consulta
fuentes primarias y escribe solo `allowedWritePath`. En publish, usa research y evidencia
del run, y escribe solo los ocho archivos de `outputDirectory` más `submissionPath`.

No ejecutes comandos, no edites código, dependencias, configuración, estado, manifest,
resultados o logs. No elijas versiones ni conviertas recomendaciones en hechos.

Separa cambios oficiales, cambios observados, inferencias y cambios no aplicables. Toda
afirmación debe enlazar evidencia. Si falta evidencia, decláralo como unresolved.

No publiques hasta que el contexto indique `migrationStatus=verified`. Al finalizar,
deja el JSON contractual; el controlador lo validará y registrará.
```

Como el agente carece de `execute`, el orquestador principal llama a
`record-documentation` después de que el subagente entregue el archivo. No añadir
`execute` solo para comodidad.

## 13. Política de hooks

Extender `preToolUse`:

- para `migration-documenter` en research, permitir edit solo al inbox research;
- en publish, permitir edit solo bajo el output exacto y al inbox documentation;
- denegar cualquier tool de ejecución aunque aparezca por configuración externa;
- denegar edición de docs antes de `migrationStatus=verified`;
- denegar rutas no determinables y datos sensibles.

Extender `subagentStop`:

- research: bloquear si falta `research.json` válido;
- publish: bloquear si falta `documentation.json` o alguno de los ocho archivos;
- nunca interpretar la respuesta textual como evidencia de finalización.

## 14. Tests obligatorios

Cubrir al menos:

1. research permitido con manifest resuelto y migración todavía running;
2. publish denegado antes de verified;
3. hash de manifest/research incorrecto rechazado;
4. fuente no HTTPS rechazada;
5. source id inexistente rechazado;
6. official-change sin primaria rechazado;
7. paquete ajeno al manifest rechazado;
8. unresolved conservado sin invención;
9. research no modifica docs;
10. agente no dispone de execute;
11. hook permite solo inbox en research;
12. hook permite solo directorio target en publish;
13. archivo noveno rechazado;
14. ausencia de uno de los ocho archivos rechazada;
15. versión distinta del manifest rechazada;
16. fingerprint/event/commit inexistente rechazado;
17. enlace interno roto rechazado;
18. ruta local de usuario o secreto redactado/rechazado;
19. migración sin reparaciones genera texto contractual;
20. migración sin warnings genera texto contractual;
21. éxito crea commit fijo, completa run y libera lock;
22. fallo conserva technical verified y permite reintento;
23. modificación concurrente después del commit técnico rechazada;
24. dos publicaciones desde la misma evidencia producen contenido estructuralmente
    equivalente aunque el texto explicativo varíe.

## 15. Criterio de salida

- [ ] Investigación y publicación son pasos distintos.
- [ ] Research puede avanzar en paralelo sin tocar documentación final.
- [ ] Publish exige migración técnica verificada.
- [ ] El agente no tiene herramienta de ejecución.
- [ ] Existen exactamente ocho documentos finales.
- [ ] Todas las dependencias directas aparecen documentadas.
- [ ] Errores, reparaciones, warnings y conceptos tienen evidencia.
- [ ] Los hechos observados no se mezclan con cambios oficiales o inferencias.
- [ ] El facade valida contenido y diff antes de cerrar el run.
- [ ] Un fallo documental no invalida el resultado técnico.

La fase termina cuando una ejecución fixture puede investigar en paralelo, esperar la
verificación técnica, publicar los ocho documentos y cerrar el run sin modificar ningún
archivo fuera del directorio autorizado.
