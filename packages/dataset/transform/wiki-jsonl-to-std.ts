// import wtf from 'wtf_wikipedia';
import type { WikiPage } from './wiki.types';
import { cleanupSentences } from './util';

// Helper function to convert wikitext to plain text
export function wikiToStd(wikitext: WikiPage) {
    // const doc = wtf(wikitext.revision.text);
    // return doc.text();
    return cleanupSentences(mediawikitoplaintext(wikitext));
}

function mediawikitoplaintext(wikitext: WikiPage): string {
  const text = wikitext.revision.text;
  
  // Remove common MediaWiki syntax
  let plainText = text
    // Remove comments
    .replace(/<!--[\s\S]*?-->/g, '')
    
    // Remove templates/infoboxes {{...}}
    .replace(/\{\{[\s\S]*?\}\}/g, '')
    
    // Remove tables
    .replace(/\{\|[\s\S]*?\|\}/g, '')
    
    // Remove file/image links
    .replace(/\[\[(File|Image):[\s\S]*?\]\]/gi, '')
    
    // Remove category links
    .replace(/\[\[Category:[\s\S]*?\]\]/gi, '')
    
    // Handle internal links - keep the text but remove the link
    .replace(/\[\[([^|\]]*)\|([^\]]*)\]\]/g, '$2') // [[link|text]] -> text
    .replace(/\[\[([^\]]*)\]\]/g, '$1') // [[link]] -> link
    
    // Remove external links
    .replace(/\[https?:\/\/[^\s\]]*\s([^\]]*)\]/g, '$1') // [http://example.com text] -> text
    .replace(/\[https?:\/\/[^\s\]]*\]/g, '') // [http://example.com] -> ''
    
    // Remove formatting
    .replace(/'''([^']*)'''/g, '$1') // Bold
    .replace(/''([^']*)''/g, '$1') // Italic
    
    // Remove HTML tags
    .replace(/<[^>]*>/g, '')
    
    // Remove section headers
    .replace(/==+([^=]*)==+/g, '$1')
    
    // Remove list markers
    .replace(/^[*#:;]+\s*/gm, '')
    
    // Remove references
    .replace(/<ref[^>]*>[\s\S]*?<\/ref>/g, '')
    .replace(/<ref[^>]*\/>/g, '');
  
  // Clean up whitespace
  plainText = plainText
    .replace(/\n{3,}/g, '\n\n') // Replace multiple newlines with just two
    .replace(/^\s+|\s+$/g, ''); // Trim whitespace
  
  return plainText;
}