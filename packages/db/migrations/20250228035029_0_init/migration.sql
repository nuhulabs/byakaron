-- CreateEnum
CREATE TYPE "datasources_type" AS ENUM ('mysql_dump', 'postgres_dump', 'csv', 'json', 'yaml', 'xml', 'html', 'markdown', 'text');

-- CreateTable
CREATE TABLE "grammar_rules" (
    "id" SERIAL NOT NULL,
    "type" TEXT,
    "description" TEXT,

    CONSTRAINT "grammar_rules_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "rules" (
    "id" SERIAL NOT NULL,
    "keyword" TEXT,
    "replace_keyword" TEXT,
    "error_description" TEXT,
    "grammar_rule_id" INTEGER,

    CONSTRAINT "rules_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "sentences" (
    "id" SERIAL NOT NULL,
    "text" TEXT,
    "created_at" TIMESTAMP(3),

    CONSTRAINT "sentences_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "words" (
    "id" SERIAL NOT NULL,
    "sentence_id" INTEGER,
    "text" TEXT,
    "position" INTEGER,

    CONSTRAINT "words_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "word_groups" (
    "id" SERIAL NOT NULL,
    "prev_id" INTEGER,
    "next_id" INTEGER,
    "weight" DOUBLE PRECISION,

    CONSTRAINT "word_groups_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "datasources" (
    "id" SERIAL NOT NULL,
    "name" TEXT NOT NULL,
    "type" "datasources_type" NOT NULL,
    "url" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "datasources_pkey" PRIMARY KEY ("id")
);

-- AddForeignKey
ALTER TABLE "rules" ADD CONSTRAINT "rules_grammar_rule_id_fkey" FOREIGN KEY ("grammar_rule_id") REFERENCES "grammar_rules"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "words" ADD CONSTRAINT "words_sentence_id_fkey" FOREIGN KEY ("sentence_id") REFERENCES "sentences"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "word_groups" ADD CONSTRAINT "word_groups_prev_id_fkey" FOREIGN KEY ("prev_id") REFERENCES "words"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "word_groups" ADD CONSTRAINT "word_groups_next_id_fkey" FOREIGN KEY ("next_id") REFERENCES "words"("id") ON DELETE SET NULL ON UPDATE CASCADE;
