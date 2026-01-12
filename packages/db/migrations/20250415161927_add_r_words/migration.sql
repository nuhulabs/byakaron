-- CreateTable
CREATE TABLE "public"."romanized_words" (
    "word_id" INTEGER NOT NULL,
    "value" TEXT NOT NULL,

    CONSTRAINT "romanized_words_pkey" PRIMARY KEY ("word_id")
);

-- AddForeignKey
ALTER TABLE "public"."romanized_words" ADD CONSTRAINT "romanized_words_word_id_fkey" FOREIGN KEY ("word_id") REFERENCES "public"."words"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
