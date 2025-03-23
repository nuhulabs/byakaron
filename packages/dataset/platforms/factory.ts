import type { Transfomer } from ".";
import { ProthomAloTransformer } from "./prothomalo";
import { WikipediaTransformer } from "./wikipedia";

const transfomers = [WikipediaTransformer, ProthomAloTransformer];
type TransfomerName = (typeof transfomers)[number]["NAME"];

class TransformerFactory {
  #transformers = transfomers;

  resolve(name: TransfomerName): Transfomer {
    const Transformer = this.#transformers.find((t) => t.NAME === name);
    if (!Transformer) throw new Error(`Transformer ${name} not found`);
    return new Transformer();
  }
}

export const transformerFactory = new TransformerFactory();
