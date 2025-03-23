import type { DataSource } from "../types";

export abstract class Transfomer {
  abstract name: string;
  abstract extract(datasource: DataSource): Promise<boolean>;
  abstract transform(datasource: DataSource): Promise<boolean>;

  async load(datasource: DataSource): Promise<boolean> {
    return this.extract(datasource);
  }
}
