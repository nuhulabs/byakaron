import { Transfomer } from ".";
import type { DataSource } from "../types";

export class ProthomAloTransformer extends Transfomer {
  static readonly NAME = "prothomalo";
  name = ProthomAloTransformer.NAME;

  extract(datasource: DataSource): Promise<boolean> {
    return Promise.resolve(true);
  }
  transform(datasource: DataSource): Promise<boolean> {
    return Promise.resolve(true);
  }
}
