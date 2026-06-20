#!/bin/bash

# Set the repository URL and file paths
REPO_URL="git@github.com:nurulhudaapon/bntk.git"
SOURCE_FILES=(
    "src/assets/rules.json:packages/core/transliteration/assets/rules.json"
    "src/assets/orva.json:packages/core/transliteration/assets/orva.json"
    "src/assets/transliteration.test.json:packages/core/transliteration/tests/transliterate.test.json"
)
TEMP_DIR=".temp_sync"

# Create temporary directory if it doesn't exist
mkdir -p "$TEMP_DIR"

# Check if the repository is already initialized
if [ ! -d "$TEMP_DIR/.git" ]; then
    echo "Initializing repository with sparse checkout..."
    cd "$TEMP_DIR"
    git init
    git remote add origin "$REPO_URL"
    # Set up sparse checkout for all files
    git sparse-checkout set $(echo "${SOURCE_FILES[@]}" | tr ' ' '\n' | cut -d':' -f2)
    git pull origin main
    cd ..
else
    echo "Updating repository..."
    cd "$TEMP_DIR"
    git pull origin main
    cd ..
fi

# Copy each file to its destination
echo "Copying files..."
for file_pair in "${SOURCE_FILES[@]}"; do
    dest_file="${file_pair%%:*}"
    source_path="${file_pair#*:}"
    target_file="$dest_file"
    echo "Copying $source_path to $target_file..."
    cp "$TEMP_DIR/$source_path" "$target_file"
done

# Clean up the temporary directory
echo "Cleaning up temporary directory..."
rm -rf "$TEMP_DIR"

echo "Sync completed successfully!"
