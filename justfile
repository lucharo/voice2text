# Build the package
build:
    rm -rf dist/
    uvx hatch build

# Publish to PyPI (requires HATCH_INDEX_USER and HATCH_INDEX_AUTH env vars, or will prompt)
publish:
    uvx hatch publish

# Build and publish
release: build publish
