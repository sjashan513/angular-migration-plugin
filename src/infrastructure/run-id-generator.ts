import { randomUUID } from "node:crypto";
import type { RunIdGenerator } from "../application/ports/run-lifecycle.js";

export class CryptoRunIdGenerator implements RunIdGenerator {
  create(): string {
    return randomUUID();
  }
}
