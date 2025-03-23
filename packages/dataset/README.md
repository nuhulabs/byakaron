# Dataset ETL Process

This document provides instructions on how to use the dataset ETL (Extract, Transform, Load) process using the `bun` commands: `bun extract`, `bun transform`, and `bun load`.

## Overview

The ETL process is designed to handle data extraction, transformation, and loading into a database. Each step of the process is handled by a specific script:

- **Extract**: Downloads data from specified sources.
- **Transform**: Processes and transforms the raw data into a structured format.
- **Load**: Loads the transformed data into a database.

## Prerequisites

- Ensure you have `bun` installed on your system.
- Ensure you have access to the data sources specified in the configuration.
- Ensure your database is set up and accessible.

## Commands

### 1. Extract

The `extract` step downloads data from various sources.

**Command**:

```bash
bun extract
```

**What it does**:

- Fetches data from the sources defined in the `DATA_SOURCES` constant.
- Downloads are executed in parallel for efficiency.

### 2. Transform

The `transform` step processes the raw data into a structured format.

**Command**:

```bash
bun transform
```

**What it does**:

- Reads the downloaded data.
- Transforms the data into sentences, word pairs, and unique words.
- Utilizes tokenization and other transformation techniques.

### 3. Load

The `load` step loads the transformed data into a database.

**Command**:

```bash
bun load
```

**What it does**:

- Connects to the database using `pg` and `pg-copy-streams`.
- Loads sentences, word pairs, and unique words into the database.
- Displays progress of the loading process.

## Configuration

- **Data Sources**: Defined in the `constant.ts` file. Ensure these are correctly set up before running the ETL process.
- **Database Connection**: Ensure your database connection details are correctly configured in the environment or configuration files.

## Error Handling

- Each step logs errors to the console. Check the logs for any issues during the ETL process.

## Conclusion

This ETL process is designed to efficiently handle large datasets by leveraging parallel processing and streaming techniques. Ensure all configurations are correct and dependencies are installed before running the commands.
