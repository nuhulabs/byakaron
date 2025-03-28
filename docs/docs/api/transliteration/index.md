# 📦 @bntk/transliteration

## transliterate()

```ts
function transliterate(text): string;
```

Defined in: [transliterate.ts:36](https://github.com/nurulhudaapon/bntk/blob/2238d24d66469246da98b70b2cf9912045ce91e7/packages/core/transliteration/src/transliterate.ts#L36)

Transliterates Bangla text written in English (romanized) to Bangla script,
following the Avro Phonetic typing method.

### Parameters

| Parameter | Type     | Description                                                      |
| --------- | -------- | ---------------------------------------------------------------- |
| `text`    | `string` | The input text in English characters to convert to Bangla script |

### Returns

`string`

The transliterated text in Bangla script

### Examples

```ts
// Basic transliteration
transliterate("ami bangla likhi");
// Returns: "আমি বাংলা লিখি"
```

```ts
// Conjunct consonants (juktakkhor)
transliterate("kSto");
// Returns: "ক্ষ্ট"
```

```ts
// Special characters
transliterate("amar kachhe 500 taka ache.");
// Returns: "আমার কাছে ৫০০ টাকা আছে।"
```

```ts
// Vowel combinations
transliterate("aei");
// Returns: "আঈ"
```

```ts
// Mixed English and Bangla
transliterate("ami website e login korlam");
// Returns: "আমি ওয়েবসাইট এ লগিন করলাম"
```
