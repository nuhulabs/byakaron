# 📦 @bntk/transliteration

## transliterate()

```ts
function transliterate(text, options): string;
```

Defined in: [transliterate.ts:164](https://github.com/nurulhudaapon/bntk/blob/a800a88ba2a08067633bfe63793a7c8b86a8a486/packages/core/transliteration/src/transliterate.ts#L164)

Transliterates text between Bangla and Latin scripts using various modes.

#### Modes:

- #### avro

  Most popular phonetic typing system for Bangla

  ```typescript
  transliterate("amar sOnar bangla", { mode: "avro" }); // → "আমার সোনার বাংলা"
  transliterate("jIbon", { mode: "avro" }); // → "জীবন"
  ```

- #### orva

  Reverse transliteration from Bangla to Latin script (beta)

  ```typescript
  transliterate("আমার সোনার বাংলা", { mode: "orva" }); // → "amar sOnar bangla"
  transliterate("জীবন", { mode: "orva" }); // → "jIbon"
  ```

- #### banglish

  Informal phonetic system matching common texting patterns (not yet implemented)

  ```typescript
  transliterate("amar shonar bangla", { mode: "banglish" }); // → "আমার সোনার বাংলা"
  transliterate("jibon", { mode: "banglish" }); // → "জীবন"
  ```

- #### lishbang
  English-speaker friendly system with systematic mappings (not yet implemented)
  ```typescript
  transliterate("ইট ইজ নট গুড।", { mode: "lishbang" }); // → "It is not good."
  transliterate("মাই নেইম ইজ আপন।", { mode: "lishbang" }); // → "My name is Apon."
  ```

### Parameters

| Parameter | Type                     | Description                             |
| --------- | ------------------------ | --------------------------------------- |
| `text`    | `string`                 | The input text to transliterate         |
| `options` | `TransliterationOptions` | Configuration options with desired mode |

### Returns

`string`

The transliterated text
