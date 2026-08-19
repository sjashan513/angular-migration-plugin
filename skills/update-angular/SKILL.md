---
name: update-angular
description: Migra un proyecto Angular a la versión objetivo indicada. Invoca la pipeline completa de migración (Hermes → Cronos/Prometeo en paralelo → Hefesto → Clío). Úsala cuando el usuario quiera actualizar, migrar o hacer upgrade de Angular.
argument-hint: "<versión objetivo> — por ejemplo: 17, 15, latest"
user-invocable: true
---

# update — Migración Angular

El usuario quiere migrar su proyecto Angular. La versión objetivo es: $ARGUMENTS

Delega el trabajo completo al agente Hermes pasándole la versión objetivo.
Hermes se encarga de leer el estado del repo, calcular los saltos pendientes
y ejecutar la pipeline autónoma salto a salto.

No hagas nada más — Hermes lo gestiona todo.
