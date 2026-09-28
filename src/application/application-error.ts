export class ApplicationError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly outcome: "blocked" | "failed" = "failed",
  ) {
    super(message);
    this.name = "ApplicationError";
  }
}
