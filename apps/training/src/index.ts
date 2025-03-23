import OpenAI from "openai";

import { prisma } from "@bntk/db";
import { tokenizeToWords } from "@bntk/tokenization";

const openai = new OpenAI({
  apiKey: "ollama",
  baseURL: "http://localhost:11434/v1",
});

const getRootWords = async (words: string[]) => {
  const prompt = words
    .map((word) => `Find the root word for: ${word}`)
    .join("\n");
  const response = await openai.completions.create({
    model: "gemma3",
    prompt: `${prompt} (only return Bangla words)`,
    max_tokens: 100,
  });

  return response.choices[0].text
    .trim()
    .split("\n")
    .map(tokenizeToWords)
    .flat();
};

const main = async () => {
  const words = await prisma.words.findMany();
  console.log(words);

  const wordValues = words.map((word) => word.value);
  const rootWords = await getRootWords(wordValues);

  console.log({
    wordValues,
    rootWords,
  });

  for (let i = 0; i < words.length; i++) {
    const rootWord = rootWords[i];
    const rootWordEntry = await prisma.words.findFirst({
      where: { value: rootWord },
    });

    if (rootWordEntry) {
      await prisma.word_roots.create({
        data: {
          word_id: words[i].id,
          root_id: rootWordEntry.id,
        },
      });
    }
  }
};

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
