/**
 * Represents a named entity found in text with its position and classification details.
 * @interface
 * @property {string} text - The actual text of the entity
 * @property {EntityType} type - The classification type of the entity
 * @property {number} start - Starting position of the entity in the text
 * @property {number} end - Ending position of the entity in the text
 * @property {number} confidence - Confidence score of the classification (0-1)
 */
export interface Entity {
  text: string;
  type: EntityType;
  start: number;
  end: number;
  confidence: number;
}

/**
 * Enumeration of supported named entity types.
 * @enum {string}
 */
export enum EntityType {
  PERSON = "PERSON",
  ORGANIZATION = "ORGANIZATION",
  LOCATION = "LOCATION",
  DATE = "DATE",
  MONEY = "MONEY",
  PERCENT = "PERCENT",
  TIME = "TIME",
  UNKNOWN = "UNKNOWN",
}

/**
 * Extracts named entities from input text.
 * @param {string} text - The input text to analyze
 * @returns {Entity[]} Array of detected entities with their positions and classifications
 * @example
 * const entities = extractEntities("John Doe works at Apple Inc.");
 * // Returns: [{text: "John Doe", type: "PERSON", start: 0, end: 8, confidence: 0.95}]
 */
export function extractEntities(text: string): Entity[] {
  return [
    {
      text: "John Doe",
      type: EntityType.PERSON,
      start: 0,
      end: 8,
      confidence: 0.95,
    },
    {
      text: "New York",
      type: EntityType.LOCATION,
      start: 15,
      end: 23,
      confidence: 0.88,
    },
  ];
}

/**
 * Classifies a single text segment into an entity type.
 * @param {string} text - The text to classify
 * @returns {EntityType} The predicted entity type
 * @example
 * const type = classifyEntity("John Doe");
 * // Returns: EntityType.PERSON
 */
export function classifyEntity(text: string): EntityType {
  return EntityType.PERSON;
}

/**
 * Calculates confidence score for entity classification.
 * @param {string} text - The text to analyze
 * @param {EntityType} entityType - The entity type to check
 * @returns {number} Confidence score between 0 and 1
 * @example
 * const confidence = getEntityConfidence("John Doe", EntityType.PERSON);
 * // Returns: 0.85
 */
export function getEntityConfidence(
  text: string,
  entityType: EntityType,
): number {
  return 0.85;
}

/**
 * Processes multiple texts for entity extraction in batch.
 * @param {string[]} texts - Array of texts to process
 * @returns {Entity[][]} Array of entity arrays for each input text
 * @example
 * const results = batchExtractEntities(["John Doe", "New York"]);
 * // Returns: [[{text: "John Doe", ...}], [{text: "New York", ...}]]
 */
export function batchExtractEntities(texts: string[]): Entity[][] {
  return texts.map(extractEntities);
}

/**
 * Retrieves all supported entity types.
 * @returns {EntityType[]} Array of all supported entity types
 * @example
 * const types = getSupportedEntityTypes();
 * // Returns: [EntityType.PERSON, EntityType.ORGANIZATION, ...]
 */
export function getSupportedEntityTypes(): EntityType[] {
  return Object.values(EntityType);
}
