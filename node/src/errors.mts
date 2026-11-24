// The errors the package raises on purpose (docs/design/typescript_package.md,
// "Errors a user can act on"). KomiraError carries the fields of the Python
// package's error: the ABI status, the engine's named code and the step, each
// null when it does not apply. Only UnsupportedOperation is raised so far, by
// the Arrow import (arrow_import.mts).

export interface KomiraErrorFields {
  status?: number | null;
  code?: string | null;
  step?: string | null;
}

export class KomiraError extends Error {
  readonly status: number | null;
  readonly code: string | null;
  readonly step: string | null;

  constructor(message: string, fields: KomiraErrorFields = {}) {
    super(message);
    this.name = new.target.name;
    this.status = fields.status ?? null;
    this.code = fields.code ?? null;
    this.step = fields.step ?? null;
  }
}

// komira refused a construct by name: here, an Arrow format the import does
// not map.
export class UnsupportedOperation extends KomiraError {}
