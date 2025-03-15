import { PrismaClient } from "@prisma/client";
export type * as DataTypes from "@prisma/client";

export const prisma = new PrismaClient();
