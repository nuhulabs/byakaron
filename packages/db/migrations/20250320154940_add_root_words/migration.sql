-- CreateTable
CREATE TABLE "public"."word_roots" (
    "word_id" INTEGER NOT NULL,
    "root_id" INTEGER NOT NULL,

    CONSTRAINT "word_roots_pkey" PRIMARY KEY ("word_id","root_id")
);

-- AddForeignKey
ALTER TABLE "public"."word_roots" ADD CONSTRAINT "word_roots_word_id_fkey" FOREIGN KEY ("word_id") REFERENCES "public"."words"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "public"."word_roots" ADD CONSTRAINT "word_roots_root_id_fkey" FOREIGN KEY ("root_id") REFERENCES "public"."words"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
