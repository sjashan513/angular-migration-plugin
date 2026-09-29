import type { AngularMajor, ProjectId } from "../../domain/identity.js";

export interface ProjectFacts {
  readonly projectId: ProjectId;
  readonly angularMajor: AngularMajor;
}

export interface ProjectFactsReader {
  readProjectFacts(projectRoot: string): Promise<ProjectFacts>;
}
