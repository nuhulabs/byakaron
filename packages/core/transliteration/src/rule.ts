import { readFileSync } from "node:fs";
import { ZON } from "zzon";

export const getRules = async () => {
  // wait 5 seconds
  const fileStr = readFileSync("assets/rules.zon", "utf-8");
  return ZON.parse(fileStr);
};
