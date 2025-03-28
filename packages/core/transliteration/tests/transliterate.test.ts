import { transliterate } from "../src/transliterate";

describe("transliterate", () => {
  test("should transliterate basic transliteration", () => {
    expect(transliterate("amar nam apon")).toBe("আমার নাম আপন");
  });

  test("should transliterate a greeting sentence", () => {
    expect(transliterate("kemon achO bondhu, onek din por dekha")).toBe(
      "কেমন আছো বন্ধু, অনেক দিন পর দেখা",
    );
  });

  // test("should transliterate a complex sentence with punctuation", () => {
  //   expect(
  //     transliterate("ami banglay gan gaite bhalObashi, tumi ki gaO?"),
  //   ).toBe("আমি বাংলায় গান গাইতে ভালোবাসি, তুমি কি গাও?");
  // });

  // test("should transliterate a sentence about weather", () => {
  //   expect(transliterate("ajke baire khub brishti hocche, ghore thakbo")).toBe(
  //     "আজকে বাইরে খুব বৃষ্টি হচ্ছে, ঘরে থাকবো",
  //   );
  // });

  // test("should transliterate a sentence about food", () => {
  //   expect(transliterate("ami macher jhol ar bhat khete khub bhalobashi")).toBe(
  //     "আমি মাছের ঝোল আর ভাত খেতে খুব ভালোবাসি",
  //   );
  // });

  // test("should transliterate a sentence about family", () => {
  //   expect(
  //     transliterate(
  //       "amar poribar e amra char jon, baba ma ami ar amar choto bon",
  //     ),
  //   ).toBe("আমার পরিবার এ আমরা চার জন, বাবা মা আমি আর আমার ছোটো বোন");
  // });

  // test("should transliterate a sentence about education", () => {
  //   expect(
  //     transliterate(
  //       "ami ekhon bishwobidyaloy e computer science nie porashona korchi",
  //     ),
  //   ).toBe("আমি এখন বিশ্ববিদ্যালয় এ কম্পিউটার সাইন্স নিয়ে পড়াশোনা করছি");
  // });

  // test("should transliterate a sentence about travel", () => {
  //   expect(
  //     transliterate(
  //       "goto bochhor ami cox's bazar gechilam, samudro dekhe khub anondo peyechilam",
  //     ),
  //   ).toBe("গত বছর আমি কক্স'স বাজার গেছিলাম, সমুদ্র দেখে খুব আনন্দ পেয়েছিলাম");
  // });

  // test("should transliterate a sentence about future plans", () => {
  //   expect(
  //     transliterate(
  //       "ami bhobishyote ekjon bhalo programmer hote chai, tai khub porashona kori",
  //     ),
  //   ).toBe("আমি ভবিষ্যতে একজন ভালো প্রোগ্রামার হতে চাই, তাই খুব পড়াশোনা করি");
  // });

  // test("should transliterate a sentence about hobbies", () => {
  //   expect(
  //     transliterate(
  //       "amar shoukhin kaj holo boi pora, chhobi aka, ar programming kora",
  //     ),
  //   ).toBe("আমার শৌখিন কাজ হলো বই পড়া, ছবি আঁকা, আর প্রোগ্রামিং করা");
  // });

  // test("should transliterate a complex sentence about culture", () => {
  //   expect(
  //     transliterate(
  //       "bangladesh er lokio songskriti khub somriddho, ekhane nana dhoroner utsob palan kora hoy",
  //     ),
  //   ).toBe(
  //     "বাংলাদেশ এর লোকিও সংস্কৃতি খুব সমৃদ্ধ, এখানে নানা ধরনের উৎসব পালন করা হয়",
  //   );
  // });
});
