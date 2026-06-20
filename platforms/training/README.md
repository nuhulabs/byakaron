# Bangla Spellcheck LSP Server

This is a Language Server Protocol (LSP) server implementation for Bangla language spellchecking. It provides real-time spelling error detection and correction suggestions for Bangla text.

## Features

- Real-time Bangla text spellchecking
- Integration with MongoDB for dictionary storage
- Spelling error diagnostics with suggestions
- Completion provider for correction suggestions
- Cross-platform support (browser, mobile, desktop)

## Prerequisites

- Node.js 14.x or higher
- MongoDB 4.x or higher

## Installation

```bash
# Clone the repository
git clone https://github.com/your-username/bangla-spellcheck-lsp.git

# Install dependencies
cd bangla-spellcheck-lsp
npm install
```

## Configuration

Create a `.env` file in the root directory with the following variables:

```
MONGODB_URI=mongodb://localhost:27017
DB_NAME=bengali_spellcheck
LSP_PORT=3000
```

## Usage

### Starting the Server

```bash
# Build the project
npm run build

# Start the server
npm start
```

### Development Mode

```bash
npm run dev
```

## Database Setup

The server requires a MongoDB database with a dictionary collection. You can populate the dictionary with Bangla words using the provided scripts:

```bash
# Import a basic Bangla dictionary
npm run import-dictionary
```

## Integration with Clients

### VS Code Extension

To use this LSP server with VS Code, you can create an extension that connects to this server. See the [VS Code Language Server Extension Guide](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide) for details.

### Browser Integration

For browser integration, you can use the [Monaco Editor](https://microsoft.github.io/monaco-editor/) with the LSP client adapter.

### Mobile Integration

For mobile apps, you can connect to the LSP server using WebSockets or HTTP.

## API

The server implements the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/), providing the following capabilities:

- Text document synchronization
- Diagnostics for spelling errors
- Completion items for correction suggestions

## License

MIT
