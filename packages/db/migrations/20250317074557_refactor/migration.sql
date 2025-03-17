/*
  Warnings:

  - The values [CONJ] on the enum `pos_tag` will be removed. If these variants are still used in the database, this will fail.
  - You are about to drop the column `position` on the `words` table. All the data in the column will be lost.
  - You are about to drop the column `sentence_id` on the `words` table. All the data in the column will be lost.
  - You are about to drop the column `text` on the `words` table. All the data in the column will be lost.
  - You are about to drop the `datasources` table. If the table is not empty, all the data it contains will be lost.
  - You are about to drop the `sentences` table. If the table is not empty, all the data it contains will be lost.
  - You are about to drop the `word_groups` table. If the table is not empty, all the data it contains will be lost.
  - A unique constraint covering the columns `[value]` on the table `words` will be added. If there are existing duplicate values, this will fail.

*/
-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "warehouse";

-- CreateEnum
CREATE TYPE "warehouse"."datasources_type" AS ENUM ('mysql_dump', 'postgres_dump', 'csv', 'json', 'yaml', 'xml', 'html', 'markdown', 'text');

-- AlterEnum
BEGIN;
CREATE TYPE "public"."pos_tag_new" AS ENUM ('ADJ', 'ADP', 'ADV', 'AUX', 'CCONJ', 'DET', 'INTJ', 'NOUN', 'NUM', 'PART', 'PRON', 'PROPN', 'PUNCT', 'SCONJ', 'SYM', 'VERB', 'X');
ALTER TYPE "public"."pos_tag" RENAME TO "pos_tag_old";
ALTER TYPE "public"."pos_tag_new" RENAME TO "pos_tag";
DROP TYPE "public"."pos_tag_old";
COMMIT;

-- DropForeignKey
ALTER TABLE "public"."sentences" DROP CONSTRAINT "sentences_datasource_id_fkey";

-- DropForeignKey
ALTER TABLE "public"."word_groups" DROP CONSTRAINT "word_groups_next_id_fkey";

-- DropForeignKey
ALTER TABLE "public"."word_groups" DROP CONSTRAINT "word_groups_prev_id_fkey";

-- DropForeignKey
ALTER TABLE "public"."words" DROP CONSTRAINT "words_sentence_id_fkey";

-- DropIndex
DROP INDEX "public"."words_sentence_id_idx";

-- DropIndex
DROP INDEX "public"."words_text_key";

-- AlterTable
ALTER TABLE "public"."words" DROP COLUMN "position",
DROP COLUMN "sentence_id",
DROP COLUMN "text",
ADD COLUMN     "value" TEXT;

-- DropTable
DROP TABLE "public"."datasources";

-- DropTable
DROP TABLE "public"."sentences";

-- DropTable
DROP TABLE "public"."word_groups";

-- DropEnum
DROP TYPE "public"."datasources_type";

-- CreateTable
CREATE TABLE "warehouse"."sentences" (
    "id" SERIAL NOT NULL,
    "text" TEXT,
    "created_at" TIMESTAMP(3),
    "datasource_id" INTEGER,

    CONSTRAINT "sentences_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "warehouse"."sentence_words" (
    "sentence_id" INTEGER NOT NULL,
    "word_id" INTEGER NOT NULL,
    "position" INTEGER NOT NULL,

    CONSTRAINT "sentence_words_pkey" PRIMARY KEY ("sentence_id","word_id")
);

-- CreateTable
CREATE TABLE "public"."word_pairs" (
    "prev_id" INTEGER NOT NULL,
    "next_id" INTEGER NOT NULL,
    "weight" DOUBLE PRECISION,
    "occurance" INTEGER NOT NULL DEFAULT 0,

    CONSTRAINT "word_pairs_pkey" PRIMARY KEY ("prev_id","next_id")
);

-- CreateTable
CREATE TABLE "warehouse"."datasources" (
    "id" SERIAL NOT NULL,
    "name" TEXT NOT NULL,
    "type" "warehouse"."datasources_type" NOT NULL,
    "url" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "datasources_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "words_value_key" ON "public"."words"("value");

-- AddForeignKey
ALTER TABLE "warehouse"."sentences" ADD CONSTRAINT "sentences_datasource_id_fkey" FOREIGN KEY ("datasource_id") REFERENCES "warehouse"."datasources"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "public"."word_pairs" ADD CONSTRAINT "word_pairs_prev_id_fkey" FOREIGN KEY ("prev_id") REFERENCES "public"."words"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "public"."word_pairs" ADD CONSTRAINT "word_pairs_next_id_fkey" FOREIGN KEY ("next_id") REFERENCES "public"."words"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
