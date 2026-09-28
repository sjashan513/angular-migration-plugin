import type { ProjectFactsReader } from "./ports/project-facts-reader.js";

export async function inspectProject(
  request: { readonly projectRoot: string },
  ports: { readonly facts: ProjectFactsReader },
): Promise<{
  readonly schemaVersion: 1;
  readonly projectId: string;
  readonly angularMajor: number;
}> {
  const facts = await ports.facts.readProjectFacts(request.projectRoot);
  return {
    schemaVersion: 1,
    projectId: facts.projectId,
    angularMajor: facts.angularMajor,
  };
}
