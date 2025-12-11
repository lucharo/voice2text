# Lint with ruff
lint:
    uv run ruff check --fix voice2text.py

# Build the package
build:
    rm -rf dist/
    uv run hatch build

# Publish to PyPI (reads ~/.pypirc)
publish:
    uvx twine upload dist/*

# Build and publish
release: build publish
