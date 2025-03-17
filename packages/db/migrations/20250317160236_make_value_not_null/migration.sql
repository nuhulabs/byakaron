/*
  Warnings:

  - Made the column `weight` on table `word_pairs` required. This step will fail if there are existing NULL values in that column.
  - Made the column `value` on table `words` required. This step will fail if there are existing NULL values in that column.

*/
-- AlterTable
ALTER TABLE "public"."word_pairs" ALTER COLUMN "weight" SET NOT NULL,
ALTER COLUMN "weight" SET DEFAULT 0;

-- AlterTable
ALTER TABLE "public"."words" ALTER COLUMN "value" SET NOT NULL;
