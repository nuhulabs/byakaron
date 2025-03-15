/*
  Warnings:

  - A unique constraint covering the columns `[text]` on the table `sentences` will be added. If there are existing duplicate values, this will fail.
  - A unique constraint covering the columns `[text]` on the table `words` will be added. If there are existing duplicate values, this will fail.

*/
-- AlterTable
ALTER TABLE "sentences" ADD COLUMN     "datasource_id" INTEGER;

-- CreateIndex
CREATE UNIQUE INDEX "sentences_text_key" ON "sentences"("text");

-- CreateIndex
CREATE UNIQUE INDEX "words_text_key" ON "words"("text");

-- AddForeignKey
ALTER TABLE "sentences" ADD CONSTRAINT "sentences_datasource_id_fkey" FOREIGN KEY ("datasource_id") REFERENCES "datasources"("id") ON DELETE SET NULL ON UPDATE CASCADE;
