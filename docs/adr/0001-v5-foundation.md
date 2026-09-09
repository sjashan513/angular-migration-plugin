# ADR 0001: Fundacion del controlador v5

- Estado: aceptado
- Fecha: 2026-09-09

## Contexto

El plugin necesita una frontera determinista para migrar proyectos Angular en Windows. La ejecucion debe poder reanudarse, dejar evidencia estructurada y evitar que un agente elija comandos o versiones fuera del contrato.

## Decisiones

1. La fachada publica es `scripts/angular-migration.ps1` y solo carga modulos de dominio. La logica de proyecto, estado y procesos no se duplica en el switch de la fachada.
2. La primera version soporta npm, `package-lock.json`, `package.json` y `angular.json` en la raiz del proyecto. Yarn, pnpm, workspaces multipaquete y Nx quedan bloqueados hasta una politica explicita.
3. Cada ejecucion autoriza exactamente un salto `N -> N+1`. No existe override de major.
4. Git es la unica continuidad historica entre productos anteriores. El controlador no convierte ni reutiliza estados antiguos.
5. El working tree debe estar limpio antes de crear un run. No se usan flags automaticos que relajen integridad o peer dependencies.
6. El estado de cada run se escribe atomically mediante fichero temporal y reemplazo. Un lock persistente de ownership impide dos runs activos sobre el mismo proyecto.
7. Solo se publican dos agentes funcionales: Migration Implementer y Migration Documenter. La fachada es la unica superficie tecnica que pueden invocar.
8. Los checks se descubren desde la configuracion real del proyecto. La ausencia de e2e se representa como `not-configured`, nunca como exito.
9. El dominio visual y sus runners no forman parte del producto v5.

## Consecuencias

La fachada inicial expone `inspect`, `start` y `status`. `start` crea un manifest pendiente de resolver, el estado del run, el log de eventos y el directorio de logs. Los pasos de resolucion, ejecucion, reparacion y documentacion se incorporaran sobre estos artefactos sin cambiar la frontera publica.

La salida estandar usa el envelope versionado:

```json
{
  "schemaVersion": 5,
  "command": "status",
  "ok": true,
  "status": "running",
  "data": {},
  "error": null
}
```
