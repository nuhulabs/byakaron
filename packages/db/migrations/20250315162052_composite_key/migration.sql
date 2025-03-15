/*
  Warnings:

  - The primary key for the `word_groups` table will be changed. If it partially fails, the table could be left without primary key constraint.
  - You are about to drop the column `id` on the `word_groups` table. All the data in the column will be lost.
  - Made the column `prev_id` on table `word_groups` required. This step will fail if there are existing NULL values in that column.
  - Made the column `next_id` on table `word_groups` required. This step will fail if there are existing NULL values in that column.

*/
-- DropForeignKey
ALTER TABLE "word_groups" DROP CONSTRAINT "word_groups_next_id_fkey";

-- DropForeignKey
ALTER TABLE "word_groups" DROP CONSTRAINT "word_groups_prev_id_fkey";

-- AlterTable
ALTER TABLE "word_groups" DROP CONSTRAINT "word_groups_pkey",
DROP COLUMN "id",
ALTER COLUMN "prev_id" SET NOT NULL,
ALTER COLUMN "next_id" SET NOT NULL,
ADD CONSTRAINT "word_groups_pkey" PRIMARY KEY ("prev_id", "next_id");

-- AddForeignKey
ALTER TABLE "word_groups" ADD CONSTRAINT "word_groups_prev_id_fkey" FOREIGN KEY ("prev_id") REFERENCES "words"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "word_groups" ADD CONSTRAINT "word_groups_next_id_fkey" FOREIGN KEY ("next_id") REFERENCES "words"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
