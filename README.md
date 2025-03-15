# Bengali Language Spellcheck LSP

A Language Server Protocol (LSP) implementation for Bengali language spellchecking that works across multiple platforms including browsers, mobile, and desktop applications.

## Project Structure

This project is organized as a monorepo with the following components:

- **packages/lsp**: Core logic for the Bengali spellchecker LSP implementation
- **apps/lsp**: LSP server implementation with MongoDB integration

## Features

- Real-time Bengali text spellchecking
- Spelling error detection and diagnostics
- Suggestion generation for misspelled words
- MongoDB integration for dictionary storage
- Cross-platform support (browser, mobile, desktop)
- Customizable dictionary support

## Getting Started

### Prerequisites

- Node.js 14.x or higher
- MongoDB 4.x or higher
- Bun (for package management)

### Installation

```bash
# Clone the repository
git clone https://github.com/your-username/bengali-spellcheck-lsp.git

# Install dependencies
cd bengali-spellcheck-lsp
bun install
```

### Configuration

Create a `.env` file in the root directory with the following variables:

```
MONGODB_URI=mongodb://localhost:27017
DB_NAME=bengali_spellcheck
LSP_PORT=3000
```

### Building the Project

```bash
# Build all packages
bun run build
```

### Running the Server

```bash
# Start the LSP server
cd apps/lsp
bun run start
```

## Usage

### Using the Core Logic Package

```typescript
import { BengaliSpellchecker, TextDocument } from '@bnkt/lsp';

// Create a new spellchecker instance
const spellchecker = new BengaliSpellchecker();

// Load a custom dictionary
spellchecker.loadDictionary(['বাংলা', 'ভাষা', 'অভিধান']);

// Check a document for spelling errors
const document = TextDocument.create('file:///example.txt', 'bengali', 1, 'আমি বাংলায় কথা বলি।');
const spellingErrors = await spellchecker.checkDocument(document);
```

### Connecting to the LSP Server

The LSP server can be connected to from various clients:

- **VS Code**: Create an extension that connects to the LSP server
- **Browser**: Use Monaco Editor with the LSP client adapter
- **Mobile**: Connect via WebSockets or HTTP

## Development

### Project Structure

```
.
├── packages/
│   └── lsp/            # Core logic package
│       ├── src/        # Source code
│       ├── dist/       # Compiled output
│       └── package.json
├── apps/
│   └── lsp/            # LSP server application
│       ├── src/        # Source code
│       ├── dist/       # Compiled output
│       └── package.json
├── package.json        # Root package.json
└── README.md           # This file
```

### Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT
