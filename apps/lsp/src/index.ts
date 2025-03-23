/**
 * Bangla Language Spellcheck LSP Server
 * Main entry point
 */
import { TextDocument } from "vscode-languageserver-textdocument";
import {
  CompletionItem,
  CompletionItemKind,
  Diagnostic,
  DiagnosticSeverity,
  DidChangeConfigurationNotification,
  type DocumentDiagnosticReport,
  DocumentDiagnosticReportKind,
  type InitializeParams,
  type InitializeResult,
  ProposedFeatures,
  type TextDocumentPositionParams,
  TextDocumentSyncKind,
  TextDocuments,
  createConnection,
} from "vscode-languageserver/node";

import { prisma } from "@bntk/db";
import { BengaliSpellchecker, type SpellingError } from "@bntk/lsp";

// Create a connection for the server, using Node's IPC as a transport.
// Also include all preview / proposed LSP features.
const connection = createConnection(ProposedFeatures.all);

// Create a simple text document manager.
const documents = new TextDocuments(TextDocument);

// Create the spellchecker instance
let spellchecker: BengaliSpellchecker;

let hasConfigurationCapability = false;
let hasWorkspaceFolderCapability = false;
let hasDiagnosticRelatedInformationCapability = false;

connection.onInitialize(async (params: InitializeParams) => {
  const capabilities = params.capabilities;

  // Does the client support the `workspace/configuration` request?
  // If not, we fall back using global settings.
  hasConfigurationCapability = !!(
    capabilities.workspace && !!capabilities.workspace.configuration
  );
  hasWorkspaceFolderCapability = !!(
    capabilities.workspace && !!capabilities.workspace.workspaceFolders
  );
  hasDiagnosticRelatedInformationCapability = !!(
    capabilities.textDocument &&
    capabilities.textDocument.publishDiagnostics &&
    capabilities.textDocument.publishDiagnostics.relatedInformation
  );

  // Initialize the database connection
  try {
    // Initialize the spellchecker with dictionary from the database
    spellchecker = new BengaliSpellcheckerDbtaized();
  } catch (error) {
    console.error("Failed to initialize database:", error);
    // Initialize with empty dictionary if database connection fails
    spellchecker = new BengaliSpellchecker();
  }

  const result: InitializeResult = {
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
      // Tell the client that this server supports code completion.
      completionProvider: {
        resolveProvider: true,
        triggerCharacters: [" "], // Trigger after space to check previous word
      },
      diagnosticProvider: {
        interFileDependencies: false,
        workspaceDiagnostics: false,
      },
    },
  };

  if (hasWorkspaceFolderCapability) {
    result.capabilities.workspace = {
      workspaceFolders: {
        supported: true,
      },
    };
  }

  return result;
});

connection.onInitialized(() => {
  if (hasConfigurationCapability) {
    // Register for all configuration changes.
    connection.client.register(
      DidChangeConfigurationNotification.type,
      undefined,
    );
  }
  if (hasWorkspaceFolderCapability) {
    connection.workspace.onDidChangeWorkspaceFolders((_event) => {
      connection.console.log("Workspace folder change event received.");
    });
  }
});

// The settings interface
interface BengaliSpellcheckerSettings {
  maxNumberOfProblems: number;
  // Add any other settings specific to Bangla spellchecker
}

// The global settings, used when the `workspace/configuration` request is not supported by the client.
const defaultSettings: BengaliSpellcheckerSettings = {
  maxNumberOfProblems: 1000,
};
let globalSettings: BengaliSpellcheckerSettings = defaultSettings;

// Cache the settings of all open documents
const documentSettings = new Map<
  string,
  Thenable<BengaliSpellcheckerSettings>
>();

connection.onDidChangeConfiguration((change) => {
  if (hasConfigurationCapability) {
    // Reset all cached document settings
    documentSettings.clear();
  } else {
    globalSettings = change.settings.bengaliSpellchecker || defaultSettings;
  }
  // Refresh the diagnostics
  connection.languages.diagnostics.refresh();
});

function getDocumentSettings(
  resource: string,
): Thenable<BengaliSpellcheckerSettings> {
  if (!hasConfigurationCapability) {
    return Promise.resolve(globalSettings);
  }
  let result = documentSettings.get(resource);
  if (!result) {
    result = connection.workspace.getConfiguration({
      scopeUri: resource,
      section: "bengaliSpellchecker",
    });
    documentSettings.set(resource, result);
  }
  return result;
}

// Only keep settings for open documents
documents.onDidClose((e) => {
  documentSettings.delete(e.document.uri);
});

connection.languages.diagnostics.on(async (params) => {
  const document = documents.get(params.textDocument.uri);
  if (document !== undefined) {
    return {
      kind: DocumentDiagnosticReportKind.Full,
      items: await validateTextDocument(document),
    } satisfies DocumentDiagnosticReport;
  } else {
    // We don't know the document. We don't report problems for it.
    return {
      kind: DocumentDiagnosticReportKind.Full,
      items: [],
    } satisfies DocumentDiagnosticReport;
  }
});

// The content of a text document has changed
documents.onDidChangeContent((change) => {
  validateTextDocument(change.document);
});

// Validate a text document for spelling errors
async function validateTextDocument(
  textDocument: TextDocument,
): Promise<Diagnostic[]> {
  // Get the settings for this document
  const settings = await getDocumentSettings(textDocument.uri);

  // Check the document for spelling errors
  const spellingErrors = await spellchecker.checkDocument(textDocument);

  // Limit the number of problems reported
  const limitedErrors = spellingErrors.slice(0, settings.maxNumberOfProblems);

  // Convert spelling errors to diagnostics
  const diagnostics: Diagnostic[] = limitedErrors.map((error) =>
    createDiagnosticFromSpellingError(error, textDocument),
  );

  // Send the diagnostics to the client
  connection.sendDiagnostics({ uri: textDocument.uri, diagnostics });

  return diagnostics;
}

// Create a diagnostic from a spelling error
function createDiagnosticFromSpellingError(
  error: SpellingError,
  document: TextDocument,
): Diagnostic {
  const range = {
    start: document.positionAt(error.start),
    end: document.positionAt(error.end),
  };

  const diagnostic: Diagnostic = {
    severity: DiagnosticSeverity.Warning,
    range,
    message: `Possible spelling error: "${error.word}"`,
    source: "bangla-spellcheck",
  };

  // Add suggestions as additional data
  if (error.suggestions.length > 0) {
    diagnostic.data = {
      suggestions: error.suggestions,
    };
  }

  // Add related information if the client supports it
  if (
    hasDiagnosticRelatedInformationCapability &&
    error.suggestions.length > 0
  ) {
    diagnostic.relatedInformation = [
      {
        location: {
          uri: document.uri,
          range: Object.assign({}, diagnostic.range),
        },
        message: "Suggested corrections:",
      },
      ...error.suggestions.slice(0, 3).map((suggestion) => ({
        location: {
          uri: document.uri,
          range: Object.assign({}, diagnostic.range),
        },
        message: `- ${suggestion}`,
      })),
    ];
  }

  return diagnostic;
}

connection.onDidChangeWatchedFiles((_change) => {
  // Monitored files have change in VSCode
  connection.console.log("We received a file change event");
});

// Provide completion items for misspelled words
connection.onCompletion(
  async (params: TextDocumentPositionParams): Promise<CompletionItem[]> => {
    const document = documents.get(params.textDocument.uri);
    if (!document) {
      return [];
    }

    // Get the current position
    const position = params.position;

    // Find the word at the current position
    const offset = document.offsetAt(position);

    // Check if we're in a diagnostic (misspelled word)
    const diagnostics = await connection.sendRequest(
      "textDocument/publishDiagnostics",
      {
        uri: params.textDocument.uri,
      },
    );

    // @ts-expect-error: diagnostics is not typed
    if (!diagnostics || !diagnostics.diagnostics) {
      return [];
    }

    // Find a diagnostic that contains the current position
    // @ts-expect-error: diagnostics is not typed
    const diagnostic = diagnostics.diagnostics.find((d: Diagnostic) => {
      const start = document.offsetAt(d.range.start);
      const end = document.offsetAt(d.range.end);
      return offset >= start && offset <= end;
    });

    if (!diagnostic || !diagnostic.data || !diagnostic.data.suggestions) {
      return [];
    }

    // Create completion items from suggestions
    return diagnostic.data.suggestions.map(
      (suggestion: string, index: number) => {
        return {
          label: suggestion,
          kind: CompletionItemKind.Text,
          data: index,
          sortText: String(index).padStart(5, "0"), // Sort by index
        };
      },
    );
  },
);

// This handler resolves additional information for the item selected in
// the completion list.
connection.onCompletionResolve((item: CompletionItem): CompletionItem => {
  if (typeof item.data === "number") {
    item.detail = "Bangla spelling suggestion";
    item.documentation = "Correction for misspelled Bangla word";
  }
  return item;
});

// Make the text document manager listen on the connection
// for open, change and close text document events
documents.listen(connection);

// Listen on the connection
connection.listen();

console.log("Bangla Language Spellcheck LSP Server is running...");

class BengaliSpellcheckerDbtaized extends BengaliSpellchecker {
  public async checkWord(word: string): Promise<boolean> {
    const wordRes = await prisma.words.findUnique({
      where: {
        value: word,
      },
    });

    return wordRes ? true : false;
  }
}
