import { transliterate } from "../src/transliterate";
import testData from "./transliterate.data.json";

const orva = testData.basic.orva;
const avroed = testData.basic.avroed;
const ligature = testData.ligature;

const equal = (a: string, b: string) => {
  expect(a).toEqual(b);
};

describe("transliterate", () => {
  test("mode: avro", () => {
    expect(transliterate(orva, { mode: "avro" })).toEqual(avroed);
  });

  // test("mode: avro - history and culture", () => {
  //   const orva = `bangla bhaShar itihash onek prachIn. ei bhaShaTi prachIn bhartIYo-arZo bhaSha theke biborttito. bhashatattik bisheshgZera bOlen ze, bangla bhaSha proto-magadhi prokrrito theke udbhuto, za abar pourobik sanskrrito bhaShar onZotomo upobhaSha. tin hajar bochor dhore ei bhaShaTir biborton hoeche O ekhon bisshojure choRiYe poReche. bishesh kore bharot, bangladesh, O poschimbonge bangla matrrIbhaSha hishebe bZabohrrito hoY. bishSher binnO deshe bangla bhaShabhaShI manush boshobaash koren. kOlkata, dhaka, O silhet bangla bhaShar mool kendrO. shoptodosh shatabdI theke unish shotak porjonto bangla bhaShae bishaal shahittik punorjagoron hoeche. rabIndranath Thakur, kobi nazrul islam, ishwarchandra bidyasagor, sharatchandra chaTTopadhyaY, O kazi nazrul islam bangla shahittoke bishShomonche prrotiShThito korechen.`;

  //   const avroed = `বাংলা ভাষার ইতিহাস অনেক প্রাচীন। এই ভাষাটি প্রাচীন ভারতীয়-আর্য ভাষা থেকে বিবর্তিত। ভাষাতাত্তিক বিশেষজ্ঞেরা বলেন যে, বাংলা ভাষা প্রোটো-মাগাধী প্রকৃত থেকে উদ্ভুত, যা আবার পৌরবিক সংস্কৃত ভাষার অন্যতম উপভাষা। তিন হাজার বছর ধরে এই ভাষাটির বিবর্তন হয়েছে ও এখন বিশ্বজুড়ে ছড়িয়ে পড়েছে। বিশেষ করে ভারত, বাংলাদেশ, ও পশ্চিমবঙ্গে বাংলা মাতৃভাষা হিসেবে ব্যবহৃত হয়। বিশ্বের বিন্ন দেশে বাংলা ভাষাভাষী মানুষ বসবাস করেন। কলকাতা, ঢাকা, ও সিলেট বাংলা ভাষার মূল কেন্দ্র। সপ্তদশ শতাব্দী থেকে উনিশ শতক পর্যন্ত বাংলা ভাষায় বিশাল সাহিত্যিক পুনর্জাগরণ হয়েছে। রবীন্দ্রনাথ ঠাকুর, কবি নজরুল ইসলাম, ঈশ্বরচন্দ্র বিদ্যাসাগর, শরৎচন্দ্র চট্টোপাধ্যায়, ও কাজী নজরুল ইসলাম বাংলা সাহিত্যকে বিশ্বমঞ্চে প্রতিষ্ঠিত করেছেন।`;

  //   expect(transliterate(orva, { mode: "avro" })).toBe(avroed);
  // });

  // test("mode: avro - food and festivals", () => {
  //   const orva = `bangalider khabar O utshob-anushThan bishesh shomrriddho. bangalider pranpriYo khabar-dabar holo ilish mach, chingRi mach, paNta bhaat, shemai, roshogolla, shondesh, chomchom, mishTi doi, O norom norom roshogoolla. amra khaitO procur mach O mishTi khaba. banglar bhinno bhinno onchole bhinno dhoroner khabar-dabar paoYa jay. banglar manusher jibOn Utshob-mukhor. banglar manush nObo-borsho uthzapon kore nana ronger poshake sheje shuddho banglay shubheccha binimoy kore. poyla boishakh, durga pujo, lokkhi pujo, shOrOsshoti pujo, kali pujo, bhatrrihoritiya, jamai ShaSThi, rabindra jayonti, nazrul jayonti, shorot-utshob, boshonto utshob, poush mela, ei shob utshob banglar lOkjon borShobyapi utshaho O ullasher shathe palon kore. bisheShkore durga pujo chollo'ish ghonTa lokera rongin anonde kaTaye. shorot rritute ek-ek somOy monuke mone hOy, akash mani-mukta-hoY.`;

  //   const avroed = `বাঙালিদের খাবার ও উৎসব-অনুষ্ঠান বিশেষ সমৃদ্ধ। বাঙালিদের প্রাণপ্রিয় খাবার-দাবার হলো ইলিশ মাছ, চিংড়ি মাছ, পান্তা ভাত, শেমাই, রসগোল্লা, সন্দেশ, চমচম, মিষ্টি দই, ও নরম নরম রসগোল্লা। আমরা খাইতো প্রচুর মাছ ও মিষ্টি খাবা। বাংলার ভিন্ন ভিন্ন অঞ্চলে ভিন্ন ধরনের খাবার-দাবার পাওয়া যায়। বাংলার মানুষের জীবন উৎসব-মুখর। বাংলার মানুষ নববর্ষ উথ্যাপন করে নানা রঙের পোশাকে সেজে শুদ্ধ বাংলায় শুভেচ্ছা বিনিময় করে। পয়লা বৈশাখ, দুর্গা পুজো, লক্ষ্মী পুজো, সরস্বতী পুজো, কালী পুজো, ভাত্রিহরিতীয়া, জামাই ষষ্ঠী, রবীন্দ্র জয়ন্তি, নজরুল জয়ন্তি, শরৎ-উৎসব, বসন্ত উৎসব, পৌষ মেলা, এই সব উৎসব বাংলার লোকজন বর্ষব্যাপি উৎসাহ ও উল্লাসের সাথে পালন করে। বিশেষকরে দুর্গা পুজো চল্লিশ ঘন্টা লোকেরা রঙিন আনন্দে কাটায়ে। শরৎ ঋতুতে এক-এক সময় মনুকে মনে হয়, আকাশ মণি-মুক্তা-হয়।`;

  //   expect(transliterate(orva, { mode: "avro" })).toBe(avroed);
  // });

  // test("mode: avro - literature and art", () => {
  //   const orva = `bangla shahittoer dhorohar bishaal O shomrriddho. madhzoJuuge mongolokabeZr zug shurru hoY ebong ei zuge shri krishno kirton, monoshaa monghol, chaandi monghol, O dhormomongol rochito hoYechilo. odhunik zuuge isshshorchondro bidZashagor, bonkimchondro choTTopadhdhaY, kolhaanmohon bondZOpadhdhaY, O shorot chondro choTTopadhdhaY promuukh shahittik bangla shahittoke hridoYo O montoshottae gorOe tolen. robIndronath Thakur tar kobita, gaan, naaTok, chhOTo golpo, O upOnZash dZara bangla shahitTOer noboJugOe paate den. tar por kobi nazrul islam, jibonanondo daSh, bishnu de, shukanto bhaTTacharJo, O ochintZo kumar shenongupto bangla shahitTOer shorNazhugOe abOdaan rakhen. bangla bhaShaY likhito kabZo, gaan, naaTok, O upanZasher guNagto O porimaNgoto man bishesho shera eboN bOishishTapurNo. bangali modhdhabitTo shreNir manush boraber soorapon, shangItchorch'a, o shahiTachorch'a kOre thake. shoptom shotak theke ei dhorOner chorch'a cholle ashche.`;

  //   const avroed = `বাংলা সাহিত্যের ধরোহার বিশাল ও সমৃদ্ধ। মধ্যযুগে মঙ্গলকাব্যের যুগ শুরু হয় এবং এই যুগে শ্রী কৃষ্ণ কীর্তন, মনসা মঙ্ঘল, চাণ্ডী মঙ্ঘল, ও ধর্মমঙ্গল রচিত হয়েছিলো। আধুনিক যুগে ঈশ্বরচন্দ্র বিদ্যাসাগর, বঙ্কিমচন্দ্র চট্টোপাধ্ধায়, কল্হাণমোহন বন্দ্যোপাধ্ধায়, ও শরৎ চন্দ্র চট্টোপাধ্ধায় প্রমুখ সাহিত্যিক বাংলা সাহিত্যকে হৃদয়ো ও মন্তঃসত্তায় গরে তোলেন। রবীন্দ্রনাথ ঠাকুর তার কবিতা, গান, নাটক, ছোটো গল্প, ও উপন্যাস দ্যারা বাংলা সাহিত্টের নবযুগে পাতে দেন। তার পর কবি নজরুল ইসলাম, জীবনানন্দ দাশ, বিষ্ণু দে, শুকান্ত ভাট্টাচার্যো, ও অচিন্ত্য কুমার সেনেঙ্গুপ্ত বাংলা সাহিত্যের স্বর্ণযুগে আবদান রাখেন। বাংলা ভাষায় লিখিত কাব্য, গান, নাটক, ও উপান্যাসের গুণাগত ও পরিমাণগত মান বিশেষ শেরা এবং বৈশিষ্টাপূর্ণ। বাঙালি মধ্ধবিত্ত শ্রেণির মানুষ বরাবর সুরাপান, সাংগীতচর্চা, ও সাহিটাচর্চা করে থাকে। সপ্তম শতক থেকে এই ধরনের চর্চা চল্লে আসছে।`;

  //   expect(transliterate(orva, { mode: "avro" })).toBe(avroed);
  // });

  Object.entries(ligature).forEach(([key, value]) => {
    test(`mode: avro ligature - ${key} > ${value}`, () => {
      equal(transliterate(key), value);
    });
  });

  test("performance test - should handle large text quickly", () => {
    const ALLOWED_TIME_PER_THOUSAND_CHARS = 4;
    const sampleText = orva;
    const largeText = sampleText.repeat(100);

    const startTime = performance.now();
    const result = transliterate(largeText, { mode: "avro" });
    const endTime = performance.now();

    const executionTime = endTime - startTime;
    const executionTimePerThousandChars =
      (executionTime / largeText.length) * 1000;

    // The function should process large text in reasonable time (e.g., under 100ms)
    expect(executionTimePerThousandChars).toBeLessThan(
      ALLOWED_TIME_PER_THOUSAND_CHARS,
    );

    console.log(
      `Time Taken per 1000 chars: ${(executionTime / largeText.length) * 1000}ms`,
    );

    // Verify the result is correct (check first few characters)
    expect(result.slice(0, avroed.length)).toEqual(avroed);
  });
});
