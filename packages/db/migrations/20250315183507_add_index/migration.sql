-- CreateEnum
CREATE TYPE "pos_tag" AS ENUM ('NOUN', 'VERB', 'ADJ', 'ADV', 'DET', 'PRON', 'ADP', 'CONJ', 'PUNCT', 'NUM', 'PART', 'SYM', 'X');

-- CreateEnum
CREATE TYPE "ner_tag" AS ENUM ('PERSON', 'ORGANIZATION', 'LOCATION', 'DATE', 'TIME', 'MONEY', 'QUANTITY', 'PRODUCT', 'EVENT', 'WORK_OF_ART', 'LAW', 'LANGUAGE');

-- CreateIndex
CREATE INDEX "words_sentence_id_idx" ON "words"("sentence_id");
