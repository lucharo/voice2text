# Lint with ruff
lint:
    uv run ruff check --fix v2t/

# Run module self-checks (no models needed)
check:
    python3 -m v2t.config && python3 -m v2t.backends && python3 -m v2t.bench

# Build the package
build:
    rm -rf dist/
    uv run hatch build

# Publish to PyPI (reads ~/.pypirc)
publish:
    uvx twine upload dist/*

# Build and publish
release: build publish
