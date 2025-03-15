import wtf from 'wtf_wikipedia';
import type { WikiPage } from './wiki.types';
import { cleanupSentences } from './util';

// Helper function to convert wikitext to plain text
export async function wikiToStd(wikitext: WikiPage) {
    const doc = wtf(wikitext.revision.text);
    return cleanupSentences(doc.text());
}